from pathlib import Path
import re
p=Path(__file__).parent
three=(p/'vendor/three.module.js').read_text()
three=re.sub(r'export \{[^}]+\};\s*$', '',three)
html='<!doctype html><meta charset="utf-8"><style>html,body{margin:0;width:280px;height:280px;background:transparent;overflow:hidden}canvas{display:block}</style><script type="module">'+three+'\n'+(p/'eyes.js').read_text()+'\n'+(p/'flower.js').read_text()+'\n'+(p/'orb.js').read_text()+'\n'+(p/'pet.js').read_text()+'</script>'
(p/'assets/index.html').write_text(html)
