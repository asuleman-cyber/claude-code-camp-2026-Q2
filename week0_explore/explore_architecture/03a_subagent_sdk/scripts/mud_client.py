#!/usr/bin/env python3
"""
Headless client for the TBAMUD server used by the mud-player skill.

Connects over raw TCP, performs minimal telnet option negotiation, logs in
(handling both "existing character" and "brand new character" flows), runs a
list of in-game commands one at a time, then logs out cleanly. Each run is a
fresh connection -- character state persists on the server between runs.

Usage:
    python mud_client.py <command> [<command> ...]
    python mud_client.py "north" "look" "inventory"
    python mud_client.py --raw "score"      # keep ANSI color codes
    python mud_client.py --stay "look"      # leave char in-game, socket open

Env overrides:
    MUD_HOST (default: localhost)
    MUD_PORT (default: 4000)
    MUD_USER (default: player)
    MUD_PASS (default: helloworld)
    MUD_SEX  (default: M)   -- only used if a brand new character is created
    MUD_CLASS (default: W)  -- C=Cleric T=Thief W=Warrior M=Magic-user
"""
import argparse
import os
import re
import socket
import sys
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
ANSI_RE = re.compile(rb"\x1b\[[0-9;]*[a-zA-Z]")


class MudError(RuntimeError):
    pass


class MudSession:
    def __init__(self, host, port, timeout=10):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect((host, port))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _strip_telnet(self, data: bytes) -> bytes:
        """Answer telnet option negotiation (always decline) and strip it out."""
        out = bytearray()
        i = 0
        while i < len(data):
            b = data[i]
            if b == IAC and i + 1 < len(data):
                cmd = data[i + 1]
                if cmd in (DO, DONT, WILL, WONT) and i + 2 < len(data):
                    opt = data[i + 2]
                    if cmd == DO:
                        self.sock.sendall(bytes([IAC, WONT, opt]))
                    elif cmd == WILL:
                        self.sock.sendall(bytes([IAC, DONT, opt]))
                    i += 3
                elif cmd == SB:
                    j = data.find(bytes([IAC, SE]), i)
                    i = (j + 2) if j != -1 else len(data)
                else:
                    i += 2
            else:
                out.append(b)
                i += 1
        return bytes(out)

    def read_until_idle(self, idle=0.6, max_wait=8.0) -> str:
        """Read until the server stops sending data for `idle` seconds."""
        self.sock.settimeout(idle)
        buf = bytearray()
        deadline = time.monotonic() + max_wait
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf.extend(self._strip_telnet(chunk))
        text = ANSI_RE.sub(b"", bytes(buf))
        return text.decode("utf-8", errors="replace")

    def send(self, line: str, idle=0.6, max_wait=8.0) -> str:
        self.sock.sendall(line.encode("utf-8") + b"\r\n")
        return self.read_until_idle(idle=idle, max_wait=max_wait)


def login(session: MudSession, user: str, password: str, sex: str, char_class: str) -> str:
    transcript = []

    # The server pauses ~1.5s here waiting for a terminal-type negotiation
    # timeout before sending the real banner, so use a longer idle window.
    banner = session.read_until_idle(idle=2.0, max_wait=6)
    transcript.append(banner)
    if "By what name" not in banner:
        raise MudError(f"Unexpected banner, no name prompt found:\n{banner}")

    reply = session.send(user)
    transcript.append(reply)

    if "Did I get that right" in reply:
        # Brand new character: confirm name, set password twice, sex, class.
        reply = session.send("Y")
        transcript.append(reply)
        if "Give me a password" not in reply:
            raise MudError(f"Expected new-password prompt:\n{reply}")

        reply = session.send(password)
        transcript.append(reply)
        if "retype password" not in reply:
            raise MudError(f"Expected retype-password prompt:\n{reply}")

        reply = session.send(password)
        transcript.append(reply)
        if "your sex" not in reply:
            raise MudError(f"Expected sex prompt (character creation may have failed):\n{reply}")

        reply = session.send(sex)
        transcript.append(reply)
        if "Select a class" not in reply:
            raise MudError(f"Expected class prompt:\n{reply}")

        reply = session.send(char_class)
        transcript.append(reply)

    elif "Password:" in reply:
        # Existing character.
        reply = session.send(password)
        transcript.append(reply)
        if "Wrong password" in reply:
            raise MudError("Login failed: wrong password for existing character.")
        if "Reconnecting" in reply:
            # A previous session ended without logging out cleanly (e.g. it
            # disconnected while the character was still fighting). We land
            # straight in the game world, not the menu -- skip the
            # PRESS-RETURN/menu steps below entirely.
            return "\n".join(transcript)
    else:
        raise MudError(f"Unrecognized prompt after sending username:\n{reply}")

    # From here we may see a "PRESS RETURN" MOTD screen before the main menu.
    if "PRESS RETURN" in reply:
        reply = session.send("")
        transcript.append(reply)

    if "Make your choice" not in reply:
        raise MudError(f"Never reached the main menu:\n{reply}")

    reply = session.send("1", max_wait=5)  # 1) Enter the game.
    transcript.append(reply)

    return "\n".join(transcript)


def run_commands(session: MudSession, commands: list[str]) -> list[tuple[str, str]]:
    results = []
    for cmd in commands:
        out = session.send(cmd)
        results.append((cmd, out))
    return results


def logout(session: MudSession, max_attempts=5) -> str:
    """Log out cleanly, fleeing combat first if necessary.

    `quit` is refused ("You're fighting for your life!") while the
    character is in combat, and the caller always closes the socket right
    after this returns -- so if we gave up here mid-fight, the character
    would be left fighting while disconnected. Flee and retry instead of
    ever returning early on failure.
    """
    transcript = []
    for _ in range(max_attempts):
        reply = session.send("quit", max_wait=5)
        transcript.append(reply)
        if "Make your choice" in reply:
            transcript.append(session.send("0", max_wait=3))  # 0) Exit from tbaMUD.
            return "\n".join(transcript)
        if "PRESS RETURN" in reply:
            transcript.append(session.send(""))
            continue
        # Most likely "No way! You're fighting for your life!" -- get to
        # safety before trying to quit again.
        transcript.append(session.send("flee"))
    raise MudError(
        "Could not confirm a clean logout after multiple attempts (character "
        "may still be in combat). Check status next session before assuming "
        "it's safe:\n" + "\n".join(transcript)
    )


def main():
    parser = argparse.ArgumentParser(description="Run one or more commands against the MUD.")
    parser.add_argument("commands", nargs="*", help="In-game commands to send, in order (e.g. look, north, inventory)")
    parser.add_argument("--host", default=os.environ.get("MUD_HOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MUD_PORT", "4000")))
    parser.add_argument("--user", default=os.environ.get("MUD_USER", "player"))
    parser.add_argument("--password", default=os.environ.get("MUD_PASS", "helloworld"))
    parser.add_argument("--sex", default=os.environ.get("MUD_SEX", "M"), help="Only used when creating a brand new character")
    parser.add_argument("--class", dest="char_class", default=os.environ.get("MUD_CLASS", "W"), help="C/T/W/M, only used when creating a brand new character")
    parser.add_argument("--stay", action="store_true", help="Don't log out after running commands (leaves the connection open until it times out server-side)")
    parser.add_argument("--quiet-login", action="store_true", help="Don't print the login transcript, only command output")
    args = parser.parse_args()

    session = MudSession(args.host, args.port)
    try:
        login_transcript = login(session, args.user, args.password, args.sex, args.char_class)
        if not args.quiet_login:
            print(login_transcript)
            print("=" * 60)

        for cmd, out in run_commands(session, args.commands):
            print(f"> {cmd}")
            print(out)

        if not args.stay:
            print("=" * 60)
            print(logout(session))
    except MudError as e:
        print(f"MUD ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        if not args.stay:
            session.close()


if __name__ == "__main__":
    main()
