import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// A curl request whose credential travels only via stdin config (never argv,
// see Model.curlConfigText/curlEscape), whose response cannot outgrow a byte
// budget even when the server sends chunked data with no declared
// Content-Length (`--max-filesize` does not cover that case - it acts on a
// declared length), and whose environment is the one we chose rather than the
// one this process inherited.
//
// The environment matters for the same reason the argv does: everything this
// spawns is on the path of a bearer token, and an inherited environment could
// carry BASH_ENV / LD_PRELOAD / a poisoned PATH / an HTTPS_PROXY into it -
// each of which lets another local process decide what runs, or where the
// token goes, before curl ever sees it. There is no shell here for BASH_ENV
// or PATH-resolved `bash`/`head` to matter (curl is launched directly at its
// fixed system path with `command`, an argv array Quickshell execs without a
// shell), and `clearEnvironment` plus an explicit two-entry environment means
// no proxy variable survives to redirect the request either.
//
// Pattern follows the community-reviewed `BoundedProcess` component (see
// scoop.uptime-kuma): count bytes as they stream in and kill the child the
// instant the budget is crossed, rather than buffering first and measuring
// after - by the time a length check on a fully-collected string can run, an
// unbounded response has already been fully allocated in this shell's heap.
Process {
  id: root

  property int maxBytes: 8000000
  property string statusMarker: "__HTTP__"

  // (body, status, tooLarge) - tooLarge means body/status are meaningless;
  // the response was killed mid-stream for exceeding maxBytes.
  signal finishedWith(string body, int status, bool tooLarge)

  property string _configText: ""
  property string _collected: ""
  property bool _overflowed: false

  // `-q` must be the first argument (skips ~/.curlrc); `-K -` reads
  // everything else - headers, method, body, URL, transfer limits - from
  // stdin. Fixed, absolute, never interpolated.
  command: ["/usr/bin/curl", "-q", "-K", "-"]
  clearEnvironment: true
  environment: ({ PATH: "/usr/bin", LC_ALL: "C" })
  stdinEnabled: true

  // Call this rather than setting `running` directly.
  function start(configText) {
    if (root.running) return false
    root._configText = configText
    root._collected = ""
    root._overflowed = false
    root.stdinEnabled = true
    root.running = true
    return true
  }

  onStarted: {
    write(_configText)
    _configText = ""
    stdinEnabled = false
  }

  stdout: SplitParser {
    // No marker: raw chunks, counted as they arrive. A line-delimited parser
    // would have to buffer up to a delimiter before handing anything over, so
    // the budget would be enforced after the allocation it exists to prevent.
    splitMarker: ""
    onRead: function (chunk) {
      if (root._overflowed) return
      if (root._collected.length + chunk.length > root.maxBytes) {
        root._overflowed = true
        root._collected = ""
        root.signal(15)      // SIGTERM: an answer that outgrew its budget is
        killTimer.restart()  // a refusal, not a value to truncate and keep
        return
      }
      root._collected += chunk
    }
  }

  // A child that ignores TERM does not get to keep running.
  // Declared as a property rather than a child: Process has no default
  // property, so it cannot hold one.
  property Timer killTimer: Timer {
    interval: 2000
    repeat: false
    onTriggered: root.signal(9)
  }

  onExited: {
    killTimer.stop()
    var body = root._collected
    var overflowed = root._overflowed
    root._collected = ""
    root._overflowed = false
    if (overflowed) { root.finishedWith("", 0, true); return }
    var r = Model.splitHttp(body, root.statusMarker)
    root.finishedWith(r.body, r.status, false)
  }
}
