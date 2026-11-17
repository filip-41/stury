Output docs/demo/intro.gif
Set Height 332
Source docs/demo/setup.tape

Type `stury edit '.replicas = 5 | .image = "web:1.5"' deploy.yaml`
Sleep 400ms
Enter
Sleep 2s

Type `stury -c '[css("a.story") | {href: .&href, title: .@content}]' page.html`
Sleep 400ms
Enter
Sleep 2s

Type `stury diff --old-schema v1.schema.json --new-schema v2.schema.json`
Sleep 400ms
Enter
Sleep 2s
Sleep 2s
