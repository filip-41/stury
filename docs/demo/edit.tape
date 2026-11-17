Output docs/demo/edit.gif
Set Height 596
Source docs/demo/setup.tape

Type `cat config.jsonc`
Sleep 400ms
Enter
Sleep 2s

Type `stury edit '.port = 9090 | .hosts += ["c"]' config.jsonc`
Sleep 400ms
Enter
Sleep 2s

Type `stury edit '(css("a.ad") | .&href) = "/sale"' page.html`
Sleep 400ms
Enter
Sleep 2s

Type `stury edit --diff '.replicas = 5' deploy.yaml`
Sleep 400ms
Enter
Sleep 2s
Sleep 2s
