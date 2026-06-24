On 2026-06-20 around 14:32 UTC, bare-metal node `ch-07` was OOM-killed by the
kernel and restarted on its own. Prometheus and a read-only HTTP user are
configured; the source tree is checked out at the cluster's version. A teammate
was running ad-hoc diagnostic SQL from a laptop around that time. There was no
deploy and no config change in the window.

What is the root cause, and how do we keep a debug query from doing this again?
