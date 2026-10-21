import CoddPosix
import Darwin

/// codd-holderctl: debug and test client for codd-holder.
let usage = """
    usage: codd-holderctl <command> [options]

      spawn   --dir <sessionDir> --socket <path> [--session <id>] [--holder <path>] [--cols <n>] [--rows <n>]
              [--cwd <dir>] [--ring-size <bytes>] [--env-file <path>] [--exit-linger-ms <n>] [--log <path>]
              [--timeout-ms <n>] -- <argv...>
      attach  --socket <path> [--takeover] [--from start|resync|live|<offset>]     (detach: ctrl-\\)
      send    --socket <path> [--submit] [--paste] [--escapes] [--takeover] <text>
      tail    --socket <path> [--from start|resync|live|<offset>] [--no-follow] [--takeover]
      ring    <sessionDir> [--raw] [--limit <bytes>]    (last screen from the ring file; no holder needed)
      list    --root <sessionsDir> [--json]
      kill    --dir <sessionDir>                     (SIGTERM to the holder: ends the session)
      kill    --socket <path> --signal <name|number> [--takeover]   (signal the foreground process group)

    """

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    Console.error(usage)
    exit(64)
}
let rest = Array(arguments.dropFirst())
let status: Int32
switch command {
case "spawn": status = SpawnCommand.run(rest)
case "attach": status = AttachCommand.run(rest)
case "send": status = SendCommand.run(rest)
case "tail": status = TailCommand.run(rest)
case "list": status = ListCommand.run(rest)
case "ring": status = RingCommand.run(rest)
case "kill": status = KillCommand.run(rest)
case "help", "--help", "-h":
    Console.out(usage)
    status = 0
default:
    Console.error("codd-holderctl: unknown command \(command)\n\(usage)")
    status = 64
}
exit(status)
