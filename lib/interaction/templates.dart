/// 高频互动活动的**现成模板**。
///
/// 围棋 / 井字棋 / 象棋 / 敲木鱼这类需求会反复出现。每次让模型从零写一页
/// HTML，既慢又容易把 `App.send` 接口写错；模板已经把棋盘、落子、事件
/// 和 AI 操作接口都定好，AI 只需按约定 `act` 即可。
///
/// 约定：
///  · 用户操作 → `App.send({game, event, ...})`，App 会在**工作流里**
///    起一个静默短回合（不进聊天记录）；
///  · AI 操作 → `act` 执行 `window.<game>.<method>(...)`；
///  · 模板**不**在 AI 操作后再 `App.send`，避免来回循环；
///  · 敲木鱼例外：敲击只在本地计数、不逐下调用模型，关闭时给一次汇总。
class InteractionTemplates {
  const InteractionTemplates._();

  static const List<String> games = <String>[
    'tictactoe',
    'go',
    'xiangqi',
    'muyu',
    'lottery',
  ];

  static String html(String game) {
    switch (game) {
      case 'tictactoe':
        return _tictactoe;
      case 'go':
        return _go;
      case 'xiangqi':
        return _xiangqi;
      case 'muyu':
        return _muyu;
      case 'lottery':
        return _lottery;
      default:
        throw ArgumentError('未知模板：$game');
    }
  }

  /// 这个模板默认要不要"用户操作一次 → AI 回一步"。
  ///
  /// 棋类需要：每落一子就是 AI 的回合。
  /// 敲木鱼不需要：敲 80 下就调 80 次模型，既慢又贵；敲击只在本地计数，
  /// 用户关闭面板时再给一次汇总（见 ChatPage 的关闭处理）。
  static bool defaultAutoReact(String game) => game != 'muyu';

  /// 给 AI 看的接口说明（tool 里会拼进返回值）。
  static String apiHint(String game) {
    switch (game) {
      case 'tictactoe':
        return '用户落子事件：{game:"tictactoe", event:"move", cell:0-8, board:[...], turn:"ai"}。'
            '**用户每点一次就是你的回合**：立刻用 act 执行 window.ttt.aiMove(index, "O") 下子，'
            '不要等用户说"轮到你了"。window.ttt.reset() 重开。不要重复下同一格。';
      case 'go':
        return '用户落子事件：{game:"go", event:"move", x:0-18, y:0-18, turn:"ai"}。'
            '**用户每落一子就是你的回合**：立刻用 act 执行 window.goBoard.place(x, y, "white")，'
            '不要等用户催。window.goBoard.clear() 清盘。坐标从左上角开始。';
      case 'xiangqi':
        return '用户走子事件：{game:"xiangqi", event:"move", from:[x,y], to:[x,y], piece:"车", turn:"ai"}。'
            '**用户走一步就是你的回合**：立刻用 act 执行 window.xiangqi.move([fx,fy],[tx,ty]) 走黑方；'
            'window.xiangqi.reset() 重开。棋盘 9×10，红方在下。';
      case 'muyu':
        return '用户敲击事件：{game:"muyu", event:"tap", count:n}。'
            '敲木鱼**不逐下反馈**：敲击只在本地计数，不会每一下都叫你。'
            '用户关闭面板时会收到一次汇总（敲了多少下），'
            '那时用一两句话收尾即可。';
      case 'lottery':
        return '用户抽奖结果：{game:"lottery", event:"result", prize:"..."}。'
            '**用户点"抽一次"就已经有结果**，页面会自己把 prize 发给你，'
            '不需要让用户再打字告诉你抽到了什么。'
            '要改奖项：act 执行 window.lottery.setPrizes(["一等奖","二等奖","谢谢参与"])；'
            '要主动替他抽：window.lottery.spin(true)。'
            '收到结果后用一两句话回应即可，不要重复抽、不要重开面板。';
      default:
        return '';
    }
  }

  // ------------------------------------------------------------------ 井字棋

  static const String _tictactoe = r'''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
  :root{color-scheme:light dark}
  body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
    gap:14px;font:16px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
    background:transparent;color:#16211D}
  @media (prefers-color-scheme:dark){body{color:#E9F0EC}}
  .status{font-size:13px;opacity:.65;height:18px}
  .board{display:grid;grid-template-columns:repeat(3,84px);grid-template-rows:repeat(3,84px);gap:8px}
  button{appearance:none;border:1px solid rgba(120,140,130,.35);border-radius:14px;
    background:rgba(220,235,226,.5);color:inherit;font-size:34px;font-weight:600;
    transition:transform .1s ease,background .1s ease}
  @media (prefers-color-scheme:dark){button{background:rgba(255,255,255,.06)}}
  button:active{transform:scale(.97)}
  button.taken{opacity:.9}
  .row{display:flex;gap:8px}
  .mini{appearance:none;border:0;background:transparent;color:inherit;opacity:.6;font-size:12px;padding:6px 10px}
</style></head>
<body>
  <div class="status" id="status">你执 X，先手</div>
  <div class="board" id="board"></div>
  <button class="mini" onclick="ttt.reset()">重开</button>
<script>
  (function(){
    var cells = new Array(9).fill("");
    var busy = false;
    var board = document.getElementById("board");
    var status = document.getElementById("status");
    function render(){
      board.innerHTML = "";
      cells.forEach(function(v,i){
        var b = document.createElement("button");
        b.textContent = v === "X" ? "×" : (v === "O" ? "○" : "");
        if (v) b.className = "taken";
        b.onclick = function(){ userMove(i); };
        board.appendChild(b);
      });
    }
    function userMove(i){
      if (busy || cells[i]) return;
      cells[i] = "X";
      busy = true;
      status.textContent = "等你落子…";
      render();
      App.send({game:"tictactoe", event:"move", cell:i, board:cells.slice(), turn:"ai"});
    }
    window.ttt = {
      aiMove: function(i, mark){
        if (i < 0 || i > 8 || cells[i]) return;
        cells[i] = mark || "O";
        busy = false;
        status.textContent = "轮到你了";
        render();
      },
      reset: function(){
        cells = new Array(9).fill("");
        busy = false;
        status.textContent = "你执 X，先手";
        render();
      }
    };
    render();
  })();
</script>
</body></html>''';

  // ------------------------------------------------------------------ 围棋

  static const String _go = r'''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
  :root{color-scheme:light dark}
  body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
    gap:12px;font:14px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
    background:transparent;color:#16211D}
  @media (prefers-color-scheme:dark){body{color:#E9F0EC}}
  .status{font-size:12px;opacity:.65;height:16px}
  .wrap{background:#E7C48A;border-radius:10px;padding:10px;max-width:100%;box-sizing:border-box;
    box-shadow:inset 0 0 20px rgba(90,55,20,.18)}
  canvas{touch-action:none;display:block;border-radius:4px;width:100%;height:auto;max-width:600px}
  .row{display:flex;gap:10px}
  .mini{appearance:none;border:1px solid rgba(120,140,130,.4);background:transparent;color:inherit;
    border-radius:10px;font-size:12px;padding:6px 12px}
</style></head>
<body>
  <div class="status" id="status">你执黑，点交叉点落子</div>
  <div class="wrap"><canvas id="c" width="600" height="600"></canvas></div>
  <div class="row"><button class="mini" onclick="goBoard.clear()">清盘</button></div>
<script>
  (function(){
    var N = 19, pad = 30, size = 600, step = (size - pad*2) / (N-1);
    var c = document.getElementById("c");
    var ctx = c.getContext("2d");
    var stones = {};
    var busy = false;
    var status = document.getElementById("status");

    function draw(){
      ctx.clearRect(0,0,size,size);
      ctx.strokeStyle = "rgba(70,45,20,.75)";
      ctx.lineWidth = 1;
      for (var i=0;i<N;i++){
        var p = pad + i*step;
        ctx.beginPath(); ctx.moveTo(pad, p); ctx.lineTo(size-pad, p); ctx.stroke();
        ctx.beginPath(); ctx.moveTo(p, pad); ctx.lineTo(p, size-pad); ctx.stroke();
      }
      for (var k in stones){
        var xy = k.split(","); var x = +xy[0], y = +xy[1];
        var px = pad + x*step, py = pad + y*step;
        var g = ctx.createRadialGradient(px-4, py-5, 2, px, py, step*0.48);
        if (stones[k] === "black"){ g.addColorStop(0,"#4b4b4b"); g.addColorStop(1,"#050505"); }
        else { g.addColorStop(0,"#ffffff"); g.addColorStop(1,"#c9c9c9"); }
        ctx.beginPath(); ctx.arc(px, py, step*0.46, 0, Math.PI*2); ctx.fillStyle = g; ctx.fill();
        ctx.strokeStyle = "rgba(0,0,0,.35)"; ctx.stroke();
      }
    }
    function point(evt){
      var r = c.getBoundingClientRect();
      var sx = (evt.clientX - r.left) * (size / r.width);
      var sy = (evt.clientY - r.top) * (size / r.height);
      var x = Math.round((sx - pad) / step);
      var y = Math.round((sy - pad) / step);
      if (x < 0 || x >= N || y < 0 || y >= N) return null;
      if (Math.abs(pad + x*step - sx) > step*0.48 || Math.abs(pad + y*step - sy) > step*0.48) return null;
      return {x:x, y:y};
    }
    c.addEventListener("click", function(evt){
      if (busy) return;
      var p = point(evt);
      if (!p || stones[p.x+","+p.y]) return;
      stones[p.x+","+p.y] = "black";
      busy = true;
      status.textContent = "等 AI 落子…";
      draw();
      App.send({game:"go", event:"move", x:p.x, y:p.y, color:"black", turn:"ai"});
    });
    window.goBoard = {
      place: function(x,y,color){
        if (x<0||x>=N||y<0||y>=N) return;
        stones[x+","+y] = color || "white";
        busy = false;
        status.textContent = "轮到你了";
        draw();
      },
      clear: function(){ stones = {}; busy = false; status.textContent = "你执黑，点交叉点落子"; draw(); }
    };
    draw();
  })();
</script>
</body></html>''';

  // ------------------------------------------------------------------ 象棋

  static const String _xiangqi = r'''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
  :root{color-scheme:light dark}
  body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
    gap:10px;font:13px/1.4 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
    background:transparent;color:#16211D}
  @media (prefers-color-scheme:dark){body{color:#E9F0EC}}
  .status{font-size:12px;opacity:.65;height:16px}
  .board{display:grid;grid-template-columns:repeat(9,34px);grid-template-rows:repeat(10,34px);
    background:#E7C48A;border-radius:8px;padding:6px;box-shadow:inset 0 0 18px rgba(90,55,20,.2)}
  .cell{position:relative;display:flex;align-items:center;justify-content:center}
  .cell::before,.cell::after{content:"";position:absolute;background:rgba(70,45,20,.55)}
  .cell::before{left:50%;top:0;bottom:0;width:1px}
  .cell::after{top:50%;left:0;right:0;height:1px}
  .piece{position:relative;z-index:2;width:28px;height:28px;border-radius:50%;
    background:radial-gradient(circle at 35% 30%,#fff6dd,#e7cf9d);border:1px solid #8b6a3a;
    display:flex;align-items:center;justify-content:center;font-weight:700;font-size:15px;
    color:#a12b22;box-shadow:0 1px 2px rgba(0,0,0,.2)}
  .piece.black{color:#1d1d1d}
  .sel{outline:2px solid #1F4B3F;outline-offset:2px}
  .mini{appearance:none;border:1px solid rgba(120,140,130,.4);background:transparent;color:inherit;
    border-radius:10px;font-size:12px;padding:6px 12px}
</style></head>
<body>
  <div class="status" id="status">你执红，先点棋子再点目标</div>
  <div class="board" id="board"></div>
  <button class="mini" onclick="xiangqi.reset()">重开</button>
<script>
  (function(){
    var red = ["车","马","相","仕","帅","仕","相","马","车"];
    var black = ["车","马","象","士","将","士","象","马","车"];
    var pieces = {};
    function init(){
      pieces = {};
      for (var x=0;x<9;x++){
        pieces[x+",0"] = {t:red[x], c:"red"};
        pieces[x+",9"] = {t:black[x], c:"black"};
      }
      pieces["1,2"]={t:"炮",c:"red"}; pieces["7,2"]={t:"炮",c:"red"};
      pieces["1,7"]={t:"炮",c:"black"}; pieces["7,7"]={t:"炮",c:"black"};
      for (var x=0;x<9;x+=2){
        pieces[x+",3"]={t:"兵",c:"red"};
        pieces[x+",6"]={t:"卒",c:"black"};
      }
    }
    var sel = null, busy = false;
    var board = document.getElementById("board");
    var status = document.getElementById("status");
    function render(){
      board.innerHTML = "";
      for (var y=0;y<10;y++){
        for (var x=0;x<9;x++){
          var cell = document.createElement("div");
          cell.className = "cell";
          var p = pieces[x+","+y];
          if (p){
            var d = document.createElement("div");
            d.className = "piece" + (p.c === "black" ? " black" : "");
            d.textContent = p.t;
            if (sel && sel[0] === x && sel[1] === y) d.classList.add("sel");
            cell.appendChild(d);
          }
          cell.onclick = (function(cx,cy){ return function(){ tap(cx,cy); }; })(x,y);
          board.appendChild(cell);
        }
      }
    }
    function tap(x,y){
      if (busy) return;
      if (!sel){
        if (pieces[x+","+y] && pieces[x+","+y].c === "red"){
          sel = [x,y]; render();
        }
        return;
      }
      if (sel[0] === x && sel[1] === y){ sel = null; render(); return; }
      var from = sel, piece = pieces[from[0]+","+from[1]];
      sel = null;
      if (!piece) return;
      delete pieces[from[0]+","+from[1]];
      pieces[x+","+y] = piece;
      busy = true;
      status.textContent = "等 AI 走棋…";
      render();
      App.send({game:"xiangqi", event:"move", from:from, to:[x,y], piece:piece.t, turn:"ai"});
    }
    window.xiangqi = {
      move: function(from, to){
        if (!from || !to || from.length < 2 || to.length < 2) return;
        var p = pieces[from[0]+","+from[1]];
        if (!p) return;
        delete pieces[from[0]+","+from[1]];
        pieces[to[0]+","+to[1]] = p;
        busy = false;
        status.textContent = "轮到你了";
        render();
      },
      reset: function(){ init(); sel = null; busy = false; status.textContent = "你执红，先点棋子再点目标"; render(); }
    };
    init(); render();
  })();
</script>
</body></html>''';

  // ------------------------------------------------------------------ 敲木鱼

  static const String _muyu = r'''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
  :root{color-scheme:light dark}
  body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
    gap:14px;font:15px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
    background:transparent;color:#16211D;overflow:hidden}
  @media (prefers-color-scheme:dark){body{color:#E9F0EC}}
  .count{font-size:34px;font-weight:700;letter-spacing:-1px;color:#1F4B3F}
  .label{font-size:12px;opacity:.6}
  .fish{width:190px;height:190px;border-radius:50%;border:0;position:relative;
    background:radial-gradient(circle at 35% 30%,#d9a35f,#8c5a24 65%,#5b3513);
    box-shadow:0 16px 30px rgba(80,45,10,.25),inset 0 -8px 20px rgba(0,0,0,.25);
    transition:transform .08s ease}
  .fish:active{transform:scale(.96)}
  .fish::after{content:"";position:absolute;left:22%;top:22%;width:56%;height:22%;
    border-radius:50%;background:rgba(255,255,255,.16);transform:rotate(-25deg)}
  .bless{height:44px;font-size:12px;opacity:.7;transition:opacity .3s}
  .tip{font-size:11px;opacity:.45}
</style></head>
<body>
  <div class="count" id="count">0</div>
  <div class="label">功德</div>
  <button class="fish" id="fish" aria-label="敲木鱼"></button>
  <div class="bless" id="bless">点一下，攒功德</div>
  <div class="tip">敲多少下都行；关掉时 AI 会回你一句</div>
<script>
  (function(){
    var n = 0;
    var count = document.getElementById("count");
    var bless = document.getElementById("bless");
    document.getElementById("fish").onclick = function(){
      n++;
      count.textContent = n;
      bless.textContent = "功德 +1";
      App.send({game:"muyu", event:"tap", count:n});
    };
    window.muyu = {
      bless: function(text){
        if (text) bless.textContent = String(text);
        else bless.textContent = "功德 +1";
        var el = document.getElementById("count");
        el.animate([{transform:"scale(1)"},{transform:"scale(1.08)"},{transform:"scale(1)"}],
          {duration:220, easing:"ease-out"});
      }
    };
  })();
</script>
</body></html>''';

  // ------------------------------------------------------------------ 抽奖

  static const String _lottery = r'''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
  :root{color-scheme:light dark}
  body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
    gap:16px;padding:18px;box-sizing:border-box;font:15px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
    background:transparent;color:#16211D;overflow:hidden}
  @media (prefers-color-scheme:dark){body{color:#E9F0EC}}
  .card{width:100%;max-width:360px;border-radius:20px;padding:22px 18px;box-sizing:border-box;
    background:linear-gradient(160deg,rgba(255,241,204,.9),rgba(231,196,138,.55));
    border:1px solid rgba(120,90,40,.25);box-shadow:0 14px 30px rgba(90,60,20,.18);
    display:flex;flex-direction:column;align-items:center;gap:12px}
  .title{font-size:13px;letter-spacing:.14em;opacity:.6;text-transform:uppercase}
  .prize{min-height:52px;display:flex;align-items:center;justify-content:center;text-align:center;
    font-size:26px;font-weight:800;letter-spacing:-.5px;color:#7A4A12;
    transition:transform .16s ease;transform-origin:center}
  .prize.spin{animation:pop .55s ease}
  @keyframes pop{
    0%{transform:scale(.7) rotate(-6deg);opacity:.35}
    55%{transform:scale(1.12) rotate(2deg);opacity:1}
    100%{transform:scale(1) rotate(0)}
  }
  button{appearance:none;border:0;border-radius:999px;padding:13px 30px;font:16px/1 inherit;font-weight:700;
    color:#FFF8E6;background:linear-gradient(180deg,#B5792C,#8C5A24);
    box-shadow:0 8px 18px rgba(90,55,15,.32);transition:transform .12s ease}
  button:active{transform:scale(.97)}
  button[disabled]{opacity:.55}
  .prizes{display:flex;flex-wrap:wrap;gap:6px;justify-content:center;font-size:11.5px;opacity:.72}
  .prizes span{padding:3px 9px;border-radius:999px;background:rgba(255,255,255,.5)}
  .tip{font-size:11px;opacity:.45;text-align:center}
</style></head>
<body>
  <div class="card">
    <div class="title">Lucky Draw</div>
    <div class="prize" id="prize">准备好了吗？</div>
    <button id="draw">抽一次</button>
    <div class="prizes" id="prizes"></div>
  </div>
  <div class="tip">点一下就有结果；AI 会收到并接着回应</div>
<script>
  (function(){
    var prizes = ["一等奖","二等奖","三等奖","谢谢参与","再来一次"];
    var shown = [];
    var prize = document.getElementById("prize");
    var list = document.getElementById("prizes");
    var btn = document.getElementById("draw");

    function render(){
      list.innerHTML = "";
      prizes.forEach(function(p){
        var s = document.createElement("span");
        s.textContent = p;
        list.appendChild(s);
      });
    }

    function pick(){
      var pool = prizes.length ? prizes : ["谢谢参与"];
      return pool[Math.floor(Math.random() * pool.length)];
    }

    function animate(text){
      prize.classList.remove("spin");
      // 强制重排，让动画能重复播放
      void prize.offsetWidth;
      prize.textContent = text;
      prize.classList.add("spin");
      shown.push(text);
      window.lottery.last = text;
    }

    function draw(report){
      if (btn.disabled) return;
      btn.disabled = true;
      var ticks = 0;
      prize.classList.add("spin");
      var timer = setInterval(function(){
        ticks++;
        prize.textContent = pick();
        if (ticks >= 7){
          clearInterval(timer);
          var result = pick();
          animate(result);
          btn.disabled = false;
          if (report) App.send({game:"lottery", event:"result", prize:result, history:shown.slice(-10)});
        }
      }, 70);
    }

    btn.onclick = function(){ draw(true); };

    window.lottery = {
      setPrizes: function(arr){
        if (Object.prototype.toString.call(arr) === "[object Array]" && arr.length){
          prizes = arr.map(String);
          render();
          prize.textContent = "准备好了吗？";
          window.lottery.last = "";
        }
      },
      spin: function(report){ draw(report === true); },
      get result(){ return window.lottery.last || ""; },
      get prizes(){ return prizes.slice(); }
    };

    render();
  })();
</script>
</body></html>''';
}
