# Writes a TOML document as toml-test's tagged JSON: every scalar is {"type": ..., "value": ...}, and a datetime's type is
# its `.@tag`. A number's type and spelling come from its `.@style`.
def tagged:
  . as $v
  | ($v | type) as $type
  | if $type == "object" then
      reduce ($v | keys_unsorted[]) as $k ({}; .[$k] = ($v[$k] | tagged))
    elif $type == "array" then
      [range(0; $v | length) as $i | $v[$i] | tagged]
    elif $type == "boolean" then
      {type: "bool", value: ($v | tostring)}
    elif $type == "string" then
      {type: ($v | .@tag // "string"), value: $v}
    else
      ($v | .@style) as $style
      | if $style == "inf" then {type: "float", value: (if $v > 0 then "inf" else "-inf" end)}
        elif $style == "nan" then {type: "float", value: "nan"}
        elif $style == "float" then {type: "float", value: ($v | tojson)}
        else {type: "integer", value: ($v | tojson)}
        end
    end;
tagged
