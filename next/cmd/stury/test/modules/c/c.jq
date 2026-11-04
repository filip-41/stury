module {whatever:null};
import "a" as foo;
import "d" as d {search:"./"};
import "d" as d2{search:"./"};
import "e" as e {search:"./../lib/jq"};
import "f" as f {search:"./../lib/jq"};
import "data" as $d;
def a: 0;
def c:
  if $d::d[0].this != "is a test" then error("data import is missing") else . end |
  foo::a + "c" + d::meh + e::bah;
