; A project that asks no provider for anything: no pins, and for each fetched
; program how its digest was obtained. The last entry says nothing of it, as
; one written before that was recorded.
((format ((major 2) (minor 1)))
 (intent ((resolvers ()) (sources ()) (inputs ()) (build_sources ()) (overlays ())))
 (sources ())
 (hints ())
 (fetched (((name "roc-stable") (system "x86_64-linux") (obtained Both)
            (urls ("https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz"))
            (sha256 "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f") (size 69614310))
           ((name "roc-stable") (system "aarch64-darwin") (obtained Published)
            (urls ("https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-macos_apple_silicon-2026-10-04-130536d.tar.gz"))
            (sha256 "e0147f62f072a309519cbc2a6ebfa11e4bb8bac7903d5febaf7a112d1fc2842f") (size 66810227))
           ((name "tool") (system "x86_64-linux") (obtained Computed)
            (urls ("https://example.test/releases/1.0/tool-x86_64-linux" "https://mirror.example.test/releases/1.0/tool-x86_64-linux"))
            (sha256 "2c083762ce177e407730eaa41a8257631969341716950252df3c9fefd2b070aa") (size 5900520))
           ((name "tool") (system "aarch64-linux")
            (urls ("https://example.test/releases/1.0/tool-aarch64-linux"))
            (sha256 "653a992c25f15faec87c9f6d9067a5615ede2551a1b96fa79281434de803685c") (size 4274144)))))
