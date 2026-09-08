#!/usr/bin/env python3
"""Manasprites: provision a Sprite and talk to its agent."""
import argparse
from pathlib import Path
import sys


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'sprite':
        from provision import main as provision_main
        return provision_main(sys.argv[2:])
    if len(sys.argv) > 1 and sys.argv[1] in ('prompt', 'conversations', 'watch'):
        from chat import main as chat_main
        return chat_main(sys.argv[1:])
    parser = argparse.ArgumentParser(prog='manasprites', description=__doc__)
    version = Path(__file__).with_name('CLI_VERSION').read_text().strip()
    parser.add_argument('--version', action='version', version='manasprites ' + version)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('sprite', help='create or inspect a Sprite')
    sub.add_parser('prompt', help='send a prompt and stream the response')
    sub.add_parser('conversations', help='list conversations on your Sprite')
    sub.add_parser('watch', help='stream the latest turn of a conversation')
    parser.parse_args()


def entrypoint():
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(f'manasprites: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    entrypoint()
