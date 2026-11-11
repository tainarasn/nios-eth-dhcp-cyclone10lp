/* page.h - pagina servida pelo web server do Nios em GET /  (mantida < 1 KB
 * para caber em um unico segmento TCP junto com o cabecalho HTTP) */
#ifndef PAGE_H
#define PAGE_H

static const char page_html[] =
"<!doctype html><html><head><meta charset=utf-8><title>Nios II Web Server</title>"
"<style>body{font-family:sans-serif;max-width:600px;margin:2em auto}"
"input{width:100%;font-size:1.1em}pre{background:#eee;padding:8px;white-space:pre-wrap}</style>"
"</head><body><h2>Nios II - Cyclone 10 LP</h2>"
"<p>String (max. 100 caracteres) enviada ao USER HW (+1 por caractere, 0xF7&rarr;0x00):</p>"
"<input id=s maxlength=100 placeholder='digite aqui'><p><button onclick=go()>Enviar</button></p>"
"<pre id=r></pre><script>"
"function go(){var s=document.getElementById('s').value.slice(0,100),h='';"
"for(var i=0;i<s.length;i++){var c=s.charCodeAt(i);if(c>255)c=63;h+=(c<16?'0':'')+c.toString(16)}"
"fetch('/api?h='+h).then(function(r){return r.json()}).then(function(j){var o='';"
"for(var i=0;i<j.out.length;i+=2){var c=parseInt(j.out.substr(i,2),16);o+=c?String.fromCharCode(c):'\\u2400'}"
"document.getElementById('r').textContent='Resposta: '+o+'\\nHEX in : '+j.in+'\\nHEX out: '+j.out+"
"'\\nstrings processadas: '+j.count}).catch(function(e){document.getElementById('r').textContent='Erro: '+e})}"
"</script></body></html>";

#endif
