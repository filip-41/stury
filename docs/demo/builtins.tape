Output docs/demo/builtins.gif
Set Height 178
Source docs/demo/setup.tape

Type `stury -s -c '{p90: quantile(0.9; .ms), paths: frequency(.url | parse_url.path)}' access.ndjson`
Sleep 400ms
Enter
Sleep 2s

Type `stury -s -c 'map(select(.ip | ip_in_cidr("10.0.0.0/8"))) | length' access.ndjson`
Sleep 400ms
Enter
Sleep 2s
Sleep 2s
