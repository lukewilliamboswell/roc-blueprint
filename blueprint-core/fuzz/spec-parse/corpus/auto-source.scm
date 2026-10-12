; A Spec as a platform before 0.6 printed it: a source that names no package
; set, and no explicit-sources feature. It is read, and validation refuses it.
((format ((major 2) (minor 0))) (name "auto-source")
 (systems ("x86_64-linux"))
 (sources (((name "default") (provider Auto))))
 (environments (((name "ci") (parents ()) (overlays ())
   (tools (((source "default") (name "python3")))))))
 (shells (((name "default") (environment "ci"))))
 (tasks (((name "test") (environment "ci")
   (run ("python3" "-c" "print(\"hi\")" "two words" "--literal" ""))))))
