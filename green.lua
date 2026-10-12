import discord
from discord.ext import commands
import json
import os
import asyncio
import time
from collections import defaultdict, deque

# ─── CONFIG ────────────────────────────────────────────────────────────────
TOKEN = "YOUR_USER_TOKEN_HERE"
GUILD_ID = 123456789012345678
PREFIX = "!"
WINDOW = 5.0                # seconds — shared window for ban and kick bursts
THRESHOLD = 3               # events in window -> trigger
AUDIT_LAG = 1.2
WHITELIST_FILE = os.path.join(os.path.dirname(__file__), "whitelist.json")

# permissions that qualify a role as "dangerous" for the strip
DANGEROUS_PERMS = (
    "administrator",
    "manage_channels",
    "ban_members",
    "kick_members",
)
# ───────────────────────────────────────────────────────────────────────────


def load_whitelist() -> set[int]:
    if not os.path.exists(WHITELIST_FILE):
        return set()
    try:
        with open(WHITELIST_FILE, "r") as f:
            return set(int(x) for x in json.load(f))
    except (json.JSONDecodeError, ValueError, OSError):
        return set()


def save_whitelist(ids: set[int]) -> None:
    with open(WHITELIST_FILE, "w") as f:
        json.dump(sorted(ids), f, indent=2)


class Sentinel(commands.Bot):
    def __init__(self):
        super().__init__(command_prefix=PREFIX, self_bot=True)
        self.whitelist: set[int] = load_whitelist()
        # per-guild deques: (actor_id, monotonic_ts)
        self.ban_events: dict[int, deque[tuple[int, float]]] = defaultdict(deque)
        self.kick_events: dict[int, deque[tuple[int, float]]] = defaultdict(deque)

    async def on_ready(self):
        print(f"[C] online as {self.user} ({self.user.id})")
        print(f"[C] guarding guild {GUILD_ID}")
        print(f"[C] whitelist: {sorted(self.whitelist) or 'empty'}")

    # ─── helpers ──────────────────────────────────────────────────────────
    def is_whitelisted(self, user_id: int) -> bool:
        return user_id in self.whitelist or user_id == self.user.id

    def dangerous_roles(self, member: discord.Member) -> list[discord.Role]:
        """Roles on this member that carry any of the watched permissions."""
        hits = []
        for role in member.roles:
            perms = role.permissions
            if any(getattr(perms, p, False) for p in DANGEROUS_PERMS):
                hits.append(role)
        return hits

    async def strip_dangerous(self, guild: discord.Guild, member: discord.Member, reason: str):
        if member is None or self.is_whitelisted(member.id):
            return
        roles = self.dangerous_roles(member)
        if not roles:
            print(f"[C] {member} tripped ({reason}) but carries no dangerous roles")
            return
        keep = [r for r in member.roles if r not in roles]
        try:
            await member.edit(roles=keep, reason=f"sentinel: {reason}")
            stripped = ", ".join(r.name for r in roles)
            print(f"[C] STRIPPED [{stripped}] from {member} ({member.id}) — {reason}")
        except discord.Forbidden:
            print(f"[C] can't strip {member} — my top role is below theirs")
        except discord.HTTPException as e:
            print(f"[C] strip failed for {member}: {e}")

    async def find_recent_actor(self, guild: discord.Guild, action: discord.AuditLogAction,
                                target_id: int | None = None):
        """Wait for audit log to populate, return most recent actor (optionally filtered by target)."""
        await asyncio.sleep(AUDIT_LAG)
        try:
            async for entry in guild.audit_logs(limit=8, action=action):
                if target_id is None or (entry.target and entry.target.id == target_id):
                    return entry.user
        except (discord.Forbidden, discord.HTTPException) as e:
            print(f"[C] audit log read failed: {e}")
        return None

    def _register_burst(self, store: dict[int, deque], guild_id: int, actor_id: int) -> int:
        """Append event, prune old, return count for this actor within WINDOW."""
        now = time.monotonic()
        q = store[guild_id]
        q.append((actor_id, now))
        while q and now - q[0][1] > WINDOW:
            q.popleft()
        return sum(1 for uid, _ in q if uid == actor_id)

    # ─── triggers ─────────────────────────────────────────────────────────
    async def on_guild_channel_delete(self, channel: discord.abc.GuildChannel):
        if channel.guild.id != GUILD_ID:
            return
        actor = await self.find_recent_actor(channel.guild, discord.AuditLogAction.channel_delete)
        if actor is None:
            print(f"[C] channel #{channel.name} deleted — no actor resolved")
            return
        member = channel.guild.get_member(actor.id)
        await self.strip_dangerous(channel.guild, member, f"deleted #{channel.name}")

    async def on_member_ban(self, guild: discord.Guild, user: discord.User):
        if guild.id != GUILD_ID:
            return
        actor = await self.find_recent_actor(guild, discord.AuditLogAction.ban, target_id=user.id)
        if actor is None or self.is_whitelisted(actor.id):
            return
        count = self._register_burst(self.ban_events, guild.id, actor.id)
        if count >= THRESHOLD:
            member = guild.get_member(actor.id)
            await self.strip_dangerous(guild, member, f"{count} bans in {WINDOW}s")
            self.ban_events[guild.id].clear()

    async def on_member_remove(self, member: discord.Member):
        if member.guild.id != GUILD_ID:
            return
        # could be a leave, kick, or ban. resolve via audit log — only kick matters here.
        actor = await self.find_recent_actor(member.guild, discord.AuditLogAction.kick,
                                             target_id=member.id)
        if actor is None:
            return  # voluntary leave, or ban (handled elsewhere)
        if self.is_whitelisted(actor.id):
            return
        count = self._register_burst(self.kick_events, member.guild.id, actor.id)
        if count >= THRESHOLD:
            mod = member.guild.get_member(actor.id)
            await self.strip_dangerous(member.guild, mod, f"{count} kicks in {WINDOW}s")
            self.kick_events[member.guild.id].clear()

    # ─── whitelist commands ───────────────────────────────────────────────
    async def on_message(self, message: discord.Message):
        if not message.content.startswith(PREFIX):
            return
        if message.guild is None or message.guild.id != GUILD_ID:
            return
        if not self.is_whitelisted(message.author.id):
            return

        parts = message.content[len(PREFIX):].split()
        if not parts:
            return
        cmd = parts[0].lower()

        try:
            if cmd == "wl" and len(parts) >= 2:
                sub = parts[1].lower()
                if sub == "add" and len(parts) == 3:
                    try:
                        uid = int(parts[2].strip("<@!>"))
                    except ValueError:
                        await message.edit(content="bad id")
                        return
                    self.whitelist.add(uid)
                    save_whitelist(self.whitelist)
                    await message.edit(content=f"wl add: `{uid}`")
                elif sub == "remove" and len(parts) == 3:
                    try:
                        uid = int(parts[2].strip("<@!>"))
                    except ValueError:
                        await message.edit(content="bad id")
                        return
                    self.whitelist.discard(uid)
                    save_whitelist(self.whitelist)
                    await message.edit(content=f"wl remove: `{uid}`")
                elif sub == "list":
                    ids = "\n".join(f"`{i}`" for i in sorted(self.whitelist)) or "empty"
                    await message.edit(content=f"whitelist:\n{ids}")
            elif cmd == "status":
                await message.edit(content=f"sentinel up. guarding `{GUILD_ID}`. {len(self.whitelist)} whitelisted.")
        except discord.HTTPException:
            pass


if __name__ == "__main__":
    bot = Sentinel()
    bot.run(TOKEN, bot=False)
