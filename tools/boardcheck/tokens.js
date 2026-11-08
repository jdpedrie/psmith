const TH = {
  system:{d:['#0A84FF','#1E1E1E',''],l:['#007AFF','#ECECEC',''],qd:['#93A5B5','#A3B594','#AE9BB4','#85B0AD','#B3A48D'],ql:['#5B6B7A','#6E7F63','#7A6A80','#4F7A78','#7C7060']},
  sage:{d:['#3EA36E','#15241C','#24402F'],l:['#2C7550','#E6F0E9','#CFE5D8'],qd:['#7FA48A','#9DAE78','#74A39C','#ADA184','#8AA6BE'],ql:['#5A8870','#6F7F4E','#41756F','#77705A','#516B86']},
  clay:{d:['#E46F3A','#2B1C14','#4A2A1B'],l:['#B04A22','#F7EADC','#F3D2BF'],qd:['#BC9A7E','#A0A981','#B08A93','#87A9AF','#A198B5'],ql:['#8A6A52','#6B7358','#7B5A63','#4F6E74','#6E6480']},
  slate:{d:['#4C96D9','#131D29','#1F3550'],l:['#2C65A0','#E4ECF5','#CCDDF0'],qd:['#6B8AA4','#87A99E','#9992B0','#ADA08F','#74AAB4'],ql:['#4A6E8A','#57786E','#6A6480','#7A6B5C','#3F7A85']},
  aubergine:{d:['#B87CCA','#22162A','#3A2445'],l:['#7A3A8C','#F4E9F2','#E6D1EC'],qd:['#8E6F94','#8698B4','#A39581','#83A79C','#B07E96'],ql:['#6E5378','#5A6A85','#6E6355','#4E7168','#834F6B']},
  nordic:{d:['#299CC1','#12202A','#193A47'],l:['#1C6F8E','#E2EEF4','#C8E4EF'],qd:['#88B0BF','#97A9B8','#84AEA2','#9FA2B8','#AFA1B2'],ql:['#4F8092','#5C7385','#4A7A6E','#6A6D84','#7A6E7E']}
};
function tokens(theme, appearance) {
  const t = TH[theme] || TH.slate, dk = appearance !== 'light';
  const hx = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const mix = (a, b, f) => { const A = hx(a), B = hx(b); return '#' + A.map((v, i) => Math.round(v + (B[i] - v) * f).toString(16).padStart(2, '0')).join('').toUpperCase(); };
  const [accent, chrome, hl0] = dk ? t.d : t.l, q = dk ? t.qd : t.ql;
  const v = {
    accent, chrome, hl: hl0 || mix(chrome, accent, 0.22), onAccent: '#FFFFFF',
    well: dk ? mix(chrome, '#000000', 0.24) : mix(chrome, '#FFFFFF', 0.5),
    bubble: mix(chrome, accent, dk ? 0.24 : 0.16),
    accentInk: dk ? mix(accent, '#FFFFFF', 0.45) : accent,
    panel: dk ? mix(chrome, '#000000', 0.12) : mix(chrome, '#FFFFFF', 0.25),
    raise: dk ? mix(chrome, '#FFFFFF', 0.05) : '#FFFFFF',
    code: dk ? mix(chrome, '#000000', 0.30) : mix(chrome, '#FFFFFF', 0.70),
    t1: dk ? '#E6EAEE' : '#17202A', strong: dk ? '#C9D2DB' : '#2E3A46', t2: dk ? '#9AA6B2' : '#525E6A', t3: dk ? '#7F8B97' : '#5C6773',
    line: dk ? 'rgba(255,255,255,.07)' : 'rgba(16,26,38,.09)', fill: dk ? 'rgba(255,255,255,.06)' : 'rgba(16,26,38,.05)', fill2: dk ? 'rgba(255,255,255,.10)' : 'rgba(16,26,38,.09)',
    shadow: dk ? 'rgba(0,0,0,.35)' : 'rgba(16,32,52,.12)',
    red: dk ? '#F08A80' : '#BF3A2F', redFill: dk ? 'rgba(240,138,128,.14)' : 'rgba(191,58,47,.08)', destructive: dk ? '#D9544A' : '#D93D32',
    orange: dk ? '#F2A65A' : '#A85808', orangeFill: dk ? 'rgba(242,166,90,.14)' : 'rgba(168,88,8,.10)',
    green: dk ? '#7FD3A2' : '#237A4B', greenFill: dk ? 'rgba(127,211,162,.14)' : 'rgba(35,122,75,.10)',
    sground: dk ? '#1B2027' : '#F2F2F7', sside: dk ? '#171B21' : '#EAEAF0', sgroup: dk ? '#20262E' : '#FFFFFF', sraise: dk ? '#262D36' : '#FFFFFF',
    p1: dk ? '#4C96D9' : '#2C65A0', p2: dk ? '#4FB3A9' : '#2E8F86', p3: dk ? '#B49AF0' : '#7A5CC7', p4: dk ? '#E59AC8' : '#B8538E', p5: dk ? '#8FA8F5' : '#4B63C2', p6: dk ? '#9CCB6A' : '#4F7A22',
    q1: q[0], q2: q[1], q3: q[2], q4: q[3], q5: q[4]
  };
  return Object.keys(v).map(k => '--' + k + ':' + v[k]).join(';');
}
if (typeof module !== 'undefined') module.exports = tokens;
