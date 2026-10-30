/// The page served at `/` by `UploadServer`: drop files, see progress, see what's on the iPhone.
enum UploadPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Audiobug</title>
    <style>
      :root { color-scheme: light dark; --accent: #e0862a; --line: rgba(128,128,128,.3); --muted: #8a8a8e; }
      body { font-family: -apple-system, system-ui, sans-serif; max-width: 640px; margin: 0 auto; padding: 28px 16px; line-height: 1.4; }
      h1 { font-size: 1.7rem; margin: 0 0 2px; }
      h2 { font-size: 1.05rem; margin: 28px 0 6px; }
      .sub { color: var(--muted); margin: 0 0 20px; }
      .drop { border: 2px dashed var(--muted); border-radius: 16px; padding: 44px 16px; text-align: center; cursor: pointer; transition: .15s; }
      .drop:hover, .drop.over { border-color: var(--accent); background: rgba(224,134,42,.08); }
      label { display: block; margin: 18px 0 4px; font-weight: 600; }
      input[type=text] { font: inherit; padding: 9px 10px; border: 1px solid var(--muted); border-radius: 8px; width: 100%; box-sizing: border-box; background: transparent; color: inherit; }
      ul { list-style: none; padding: 0; margin: 0; }
      li { display: flex; align-items: center; gap: 10px; padding: 9px 0; border-bottom: 1px solid var(--line); }
      .name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .status { color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
      .ok { color: #2e9b4f; } .bad { color: #d23f3f; }
      progress { width: 130px; accent-color: var(--accent); }
      .folder { color: var(--muted); font-size: .85em; }
      code { background: rgba(128,128,128,.15); padding: 2px 5px; border-radius: 4px; font-size: .9em; }
    </style>
    </head>
    <body>
    <h1>Audiobug</h1>
    <p class="sub">Add audiobooks to the iPhone over Wi-Fi.</p>
    <div class="drop" id="drop">Drop M4B, M4A or MP3 files here, or click to choose
      <input type="file" id="pick" multiple accept=".m4b,.m4a,.mp3,.aac,.mp4,.wav,.aiff,.aif,.caf,.flac" hidden>
    </div>
    <label for="folder">Folder (optional)</label>
    <input type="text" id="folder" list="folders" placeholder="Library root" autocomplete="off">
    <datalist id="folders"></datalist>
    <h2>Uploads</h2>
    <ul id="uploads"><li class="folder" id="none">Nothing yet</li></ul>
    <h2>On the iPhone</h2>
    <ul id="books"></ul>
    <p class="sub" style="margin-top:24px">From a terminal: <code>curl -T Book.m4b "http://<span id="host"></span>/upload/Book.m4b?folder=Fiction"</code></p>
    <script>
      const $ = id => document.getElementById(id);
      const EXT = /\.(m4b|m4a|mp3|aac|mp4|wav|aiff|aif|caf|flac)$/i;
      const queue = []; let busy = false;
      $('host').textContent = location.host;
      $('drop').onclick = () => $('pick').click();
      $('pick').onchange = () => { add([...$('pick').files]); $('pick').value = ''; };
      ['dragenter', 'dragover'].forEach(e => $('drop').addEventListener(e, ev => { ev.preventDefault(); $('drop').classList.add('over'); }));
      ['dragleave', 'drop'].forEach(e => $('drop').addEventListener(e, ev => { ev.preventDefault(); $('drop').classList.remove('over'); }));
      $('drop').addEventListener('drop', ev => add([...ev.dataTransfer.files]));
      window.addEventListener('beforeunload', ev => { if (busy) ev.preventDefault(); });

      function add(files) {
        for (const f of files) {
          const li = row(f.name);
          if (!EXT.test(f.name)) { li.status.textContent = 'not an audiobook file'; li.status.className = 'status bad'; li.bar.remove(); continue; }
          queue.push({ f, li });
        }
        next();
      }
      function row(name) {
        const none = $('none'); if (none) none.remove();
        const li = document.createElement('li');
        li.innerHTML = '<span class="name"></span><span class="status">waiting</span><progress max="1" value="0"></progress>';
        li.querySelector('.name').textContent = name;
        li.status = li.querySelector('.status'); li.bar = li.querySelector('progress');
        $('uploads').prepend(li);
        return li;
      }
      function next() {
        if (busy || !queue.length) return;
        busy = true;
        const { f, li } = queue.shift();
        const folder = $('folder').value.trim();
        const url = '/upload/' + encodeURIComponent(f.name) + (folder ? '?folder=' + encodeURIComponent(folder) : '');
        const x = new XMLHttpRequest();
        x.open('PUT', url);
        x.upload.onprogress = e => { if (e.lengthComputable) { li.bar.value = e.loaded / e.total; li.status.textContent = Math.round(e.loaded / e.total * 100) + '%'; } };
        x.onload = () => {
          li.bar.remove();
          const ok = x.status < 300;
          li.status.textContent = ok ? 'added' + (folder ? ' to ' + folder : '') : x.responseText || ('error ' + x.status);
          li.status.className = 'status ' + (ok ? 'ok' : 'bad');
          busy = false; load(); next();
        };
        x.onerror = () => { li.bar.remove(); li.status.textContent = 'connection lost'; li.status.className = 'status bad'; busy = false; next(); };
        x.send(f);
      }
      async function load() {
        try {
          const d = await (await fetch('/api/library')).json();
          $('folders').innerHTML = d.folders.map(f => `<option value="${esc(f)}">`).join('');
          $('books').innerHTML = d.books.map(b => `<li><span class="name">${esc(b.title)}</span><span class="folder">${esc(b.folder)}</span></li>`).join('')
            || '<li class="folder">No books yet</li>';
        } catch (e) {}
      }
      const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
      load();
    </script>
    </body>
    </html>
    """#
}
