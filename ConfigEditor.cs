using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public class ConfigEditorForm : Form
{
    string configPath;
    // FTP controls
    TextBox txtHost, txtPort, txtUser, txtPass, txtRoot, txtTimeout;
    ComboBox cmbProtocol;
    CheckBox chkPassive, chkShowPass;
    // Grids
    DataGridView gridRenames, gridRemoves, gridUploads;
    // Log + status
    TextBox txtLog;
    Label lblStatus;
    Button btnSave, btnRun, btnDry;

    Color BG = Color.FromArgb(30, 30, 46);
    Color PANEL = Color.FromArgb(40, 40, 62);
    Color CARD = Color.FromArgb(49, 49, 73);
    Color ACCENT = Color.FromArgb(0, 212, 255);
    Color PURPLE = Color.FromArgb(124, 58, 237);
    Color GREEN = Color.FromArgb(34, 197, 94);
    Color RED = Color.FromArgb(239, 68, 68);

    public ConfigEditorForm()
    {
        configPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json");
        BuildUI();
        LoadConfig();
    }

    void BuildUI()
    {
        Text = "FTP Uploader  •  config.json editor";
        Size = new Size(940, 760);
        MinimumSize = new Size(860, 680);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = BG;
        Font = new Font("Segoe UI", 9.5f);

        // ---- header ----
        var header = new Panel { Dock = DockStyle.Top, Height = 74, BackColor = PANEL };
        var title = new Label {
            Text = "⚡  FTP MANAGER",
            Font = new Font("Segoe UI", 16, FontStyle.Bold),
            ForeColor = Color.White, Location = new Point(18, 8), AutoSize = true
        };
        var sub = new Label {
            Text = "Edit config.json  →  Save  →  Deploy   •   renames → removes → uploads",
            Font = new Font("Segoe UI", 9),
            ForeColor = Color.FromArgb(160, 160, 190), Location = new Point(20, 42), AutoSize = true
        };
        var badge = new Label {
            Text = "portable • WinSCP",
            Font = new Font("Segoe UI", 8, FontStyle.Bold),
            ForeColor = Color.White, BackColor = PURPLE,
            Location = new Point(820, 24), AutoSize = true, Padding = new Padding(8, 4, 8, 4)
        };
        header.Controls.AddRange(new Control[] { title, sub, badge });
        Controls.Add(header);

        // ---- tabs ----
        var tabs = new TabControl {
            Dock = DockStyle.Top, Height = 430,
            DrawMode = TabDrawMode.OwnerDrawFixed,
            Font = new Font("Segoe UI", 10, FontStyle.Bold),
            ItemSize = new Size(150, 34), SizeMode = TabSizeMode.Fixed
        };
        tabs.DrawItem += (s, e) => {
            string[] names = { "🔌  FTP", "✏️  Renames", "🗑  Removes", "📤  Uploads" };
            e.Graphics.FillRectangle(new SolidBrush(e.State.HasFlag(DrawItemState.Selected) ? CARD : PANEL), e.Bounds);
            if (e.State.HasFlag(DrawItemState.Selected))
                e.Graphics.FillRectangle(new SolidBrush(ACCENT), e.Bounds.X, e.Bounds.Bottom - 3, e.Bounds.Width, 3);
            TextRenderer.DrawText(e.Graphics, names[e.Index], tabs.Font,
                e.Bounds, e.State.HasFlag(DrawItemState.Selected) ? Color.White : Color.FromArgb(150,150,180),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        };
        tabs.BackColor = BG;

        var pgFtp = new TabPage { BackColor = BG, Padding = new Padding(14) };
        var pgRen = new TabPage { BackColor = BG, Padding = new Padding(14) };
        var pgRem = new TabPage { BackColor = BG, Padding = new Padding(14) };
        var pgUpl = new TabPage { BackColor = BG, Padding = new Padding(14) };
        tabs.TabPages.AddRange(new TabPage[] { pgFtp, pgRen, pgRem, pgUpl });
        Controls.Add(tabs);

        // ---- FTP tab ----
        int y = 10;
        AddFtpRow(pgFtp, "Host", (txtHost = NewText("ftp.example.com", 460)), ref y);
        var row2 = new Panel { Location = new Point(14, y), Size = new Size(880, 34), BackColor = BG };
        row2.Controls.Add(MkLabel("Port", 0));
        txtPort = NewText("21", 70); txtPort.Location = new Point(150, 2); row2.Controls.Add(txtPort);
        row2.Controls.Add(MkLabel("Protocol", 260));
        cmbProtocol = new ComboBox { Location = new Point(410, 2), Width = 200, DropDownStyle = ComboBoxStyle.DropDownList,
            BackColor = CARD, ForeColor = Color.White, FlatStyle = FlatStyle.Flat, Font = Font };
        cmbProtocol.Items.AddRange(new object[] { "Ftp", "FtpExplicit", "FtpImplicit", "Sftp" });
        cmbProtocol.SelectedIndex = 0; row2.Controls.Add(cmbProtocol);
        row2.Controls.Add(MkLabel("Timeout (s)", 630));
        txtTimeout = NewText("60", 70); txtTimeout.Location = new Point(790, 2); row2.Controls.Add(txtTimeout);
        pgFtp.Controls.Add(row2); y += 42;
        AddFtpRow(pgFtp, "Username", (txtUser = NewText("", 700)), ref y);
        var passPanel = new Panel { Location = new Point(14, y), Size = new Size(880, 34), BackColor = BG };
        passPanel.Controls.Add(MkLabel("Password", 0));
        txtPass = NewText("", 560); txtPass.Location = new Point(150, 2); txtPass.UseSystemPasswordChar = true;
        passPanel.Controls.Add(txtPass);
        chkShowPass = new CheckBox { Text = "show", Location = new Point(730, 6), ForeColor = Color.FromArgb(160,160,190), BackColor = BG, AutoSize = true };
        chkShowPass.CheckedChanged += (s,e) => txtPass.UseSystemPasswordChar = !chkShowPass.Checked;
        passPanel.Controls.Add(chkShowPass);
        pgFtp.Controls.Add(passPanel); y += 42;
        AddFtpRow(pgFtp, "Remote root", (txtRoot = NewText("/", 700)), ref y);
        var prow = new Panel { Location = new Point(14, y), Size = new Size(880, 34), BackColor = BG };
        chkPassive = new CheckBox { Text = "Passive mode (recommended for FTP)", Location = new Point(150, 6), ForeColor = Color.White, BackColor = BG, AutoSize = true, Checked = true, Font = new Font("Segoe UI", 10) };
        prow.Controls.Add(chkPassive); pgFtp.Controls.Add(prow); y += 42;
        var hint = new Label { Text = "Tip: values are read from config.json next to this .exe. Password stays in plain text in that file — keep the folder private.",
            Location = new Point(16, y+6), Size = new Size(860, 40), ForeColor = Color.FromArgb(140,140,170), Font = new Font("Segoe UI", 8.5f) };
        pgFtp.Controls.Add(hint);

        // ---- Renames ----
        gridRenames = NewGrid(new string[] { "remote_file_address", "remote_new_file_name" });
        gridRenames.Location = new Point(14, 10); gridRenames.Size = new Size(880, 300);
        pgRen.Controls.Add(gridRenames);
        pgRen.Controls.Add(MkGridBtns(gridRenames, 320));

        // ---- Removes ----
        gridRemoves = NewGrid(new string[] { "remote_file_address" });
        gridRemoves.Location = new Point(14, 10); gridRemoves.Size = new Size(880, 300);
        pgRem.Controls.Add(gridRemoves);
        pgRem.Controls.Add(MkGridBtns(gridRemoves, 320));
        var remHint = new Label { Text = "One path per row, relative to remote root. Empty table = nothing deleted.",
            Location = new Point(16, 362), AutoSize = true, ForeColor = Color.FromArgb(140,140,170), Font = new Font("Segoe UI", 8.5f) };
        pgRem.Controls.Add(remHint);

        // ---- Uploads ----
        gridUploads = NewGrid(new string[] { "local_file_address  (; separated)", "local_folder_address  (; separated)", "remote_folder" });
        gridUploads.Location = new Point(14, 10); gridUploads.Size = new Size(880, 270);
        pgUpl.Controls.Add(gridUploads);
        var upBtns = MkGridBtns(gridUploads, 288);
        pgUpl.Controls.Add(upBtns);
        var btnFile = StyledBtn("📄 +File…", ACCENT, new Point(380, 288), 110);
        var btnFolder = StyledBtn("📁 +Folder…", ACCENT, new Point(500, 288), 120);
        btnFile.Click += (s,e) => BrowseIntoGrid(gridUploads, 0, true);
        btnFolder.Click += (s,e) => BrowseIntoGrid(gridUploads, 1, false);
        pgUpl.Controls.Add(btnFile); pgUpl.Controls.Add(btnFolder);
        var upHint = new Label { Text = "Multiple local paths per cell: separate with  ;  —  e.g.  C:\\deploy\\a.dll ; C:\\deploy\\b.dll",
            Location = new Point(16, 330), Size = new Size(860, 40), ForeColor = Color.FromArgb(140,140,170), Font = new Font("Segoe UI", 8.5f) };
        pgUpl.Controls.Add(upHint);

        // ---- log ----
        txtLog = new TextBox { Multiline = true, ScrollBars = ScrollBars.Vertical, ReadOnly = true,
            Dock = DockStyle.Fill, BackColor = Color.FromArgb(18,18,28), ForeColor = Color.FromArgb(200,255,220),
            Font = new Font("Consolas", 9) };
        var logPanel = new Panel { Dock = DockStyle.Fill, BackColor = BG, Padding = new Padding(14, 4, 14, 6) };
        logPanel.Controls.Add(txtLog);
        Controls.Add(logPanel);

        // ---- bottom bar ----
        var bottom = new Panel { Dock = DockStyle.Bottom, Height = 62, BackColor = PANEL };
        btnSave = StyledBtn("💾  SAVE config.json", GREEN, new Point(16, 12), 220);
        btnDry = StyledBtn("🔍  DryRun", Color.FromArgb(80, 80, 110), new Point(248, 12), 130);
        btnRun = StyledBtn("🚀  EXECUTE deploy", RED, new Point(390, 12), 220);
        btnSave.Click += (s,e) => SaveConfig();
        btnDry.Click += (s,e) => RunScript(true);
        btnRun.Click += (s,e) => {
            var r = MessageBox.Show(
                "Connect to FTP and apply in order:\n1) renames  →  2) removes  →  3) uploads ?\n\nThis WILL change the server.",
                "Confirm deploy", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r == DialogResult.Yes) RunScript(false);
        };
        lblStatus = new Label { Text = "ready", Location = new Point(625, 20), Size = new Size(280, 24),
            ForeColor = Color.FromArgb(160,160,190), Font = new Font("Segoe UI", 9) };
        bottom.Controls.AddRange(new Control[] { btnSave, btnDry, btnRun, lblStatus });
        Controls.Add(bottom);

        // keep order: header top, tabs under it, bottom at bottom, log fills middle
        Controls.SetChildIndex(bottom, 0);
        Controls.SetChildIndex(logPanel, 1);
        Controls.SetChildIndex(tabs, 2);
        Controls.SetChildIndex(header, 3);
    }

    Label MkLabel(string t, int x) {
        return new Label { Text = t, Location = new Point(x, 6), Size = new Size(140, 22),
            ForeColor = Color.FromArgb(170,170,200), Font = new Font("Segoe UI", 9, FontStyle.Bold) };
    }
    TextBox NewText(string v, int w) {
        return new TextBox { Text = v, Width = w, BackColor = CARD, ForeColor = Color.White,
            BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 10) };
    }
    void AddFtpRow(Control parent, string label, TextBox box, ref int y) {
        var p = new Panel { Location = new Point(14, y), Size = new Size(880, 34), BackColor = BackColor };
        p.Controls.Add(MkLabel(label, 0));
        box.Location = new Point(150, 2);
        p.Controls.Add(box);
        parent.Controls.Add(p); y += 42;
    }
    Button StyledBtn(string t, Color c, Point loc, int w) {
        var b = new Button { Text = t, Location = loc, Size = new Size(w, 38),
            BackColor = c, ForeColor = Color.White, FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 10, FontStyle.Bold), Cursor = Cursors.Hand };
        b.FlatAppearance.BorderSize = 0;
        return b;
    }
    DataGridView NewGrid(string[] cols) {
        var g = new DataGridView {
            BackgroundColor = CARD, ForeColor = Color.White,
            GridColor = Color.FromArgb(70,70,100),
            BorderStyle = BorderStyle.None, AllowUserToAddRows = true,
            AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
            RowHeadersVisible = false, AllowUserToResizeRows = false,
            ColumnHeadersHeight = 30, RowTemplate = { Height = 28 }
        };
        g.EnableHeadersVisualStyles = false;
        g.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(60,60,90);
        g.ColumnHeadersDefaultCellStyle.ForeColor = Color.White;
        g.ColumnHeadersDefaultCellStyle.Font = new Font("Segoe UI", 9, FontStyle.Bold);
        g.DefaultCellStyle.BackColor = CARD;
        g.DefaultCellStyle.ForeColor = Color.White;
        g.DefaultCellStyle.SelectionBackColor = ACCENT;
        g.DefaultCellStyle.SelectionForeColor = Color.Black;
        foreach (var c in cols) g.Columns.Add(c, c);
        return g;
    }
    Control MkGridBtns(DataGridView g, int y) {
        var p = new Panel { Location = new Point(14, y), Size = new Size(360, 44), BackColor = BG };
        var add = StyledBtn("+ Add row", Color.FromArgb(60,60,100), new Point(0, 0), 150);
        var del = StyledBtn("− Delete row", Color.FromArgb(90,50,50), new Point(160, 0), 150);
        add.Click += (s,e) => g.Rows.Add();
        del.Click += (s,e) => { foreach (DataGridViewRow r in g.SelectedRows) if (!r.IsNewRow) g.Rows.Remove(r); };
        p.Controls.AddRange(new Control[] { add, del });
        return p;
    }

    void BrowseIntoGrid(DataGridView g, int col, bool isFile) {
        if (g.CurrentRow == null || g.CurrentRow.IsNewRow) { MessageBox.Show("Select a row first (or add one)."); return; }
        string picked = "";
        if (isFile) {
            using (var d = new OpenFileDialog { Multiselect = true }) {
                if (d.ShowDialog() != DialogResult.OK) return;
                picked = string.Join(" ; ", d.FileNames);
            }
        } else {
            using (var d = new FolderBrowserDialog()) {
                if (d.ShowDialog() != DialogResult.OK) return;
                picked = d.SelectedPath;
            }
        }
        var cur = Convert.ToString(g.CurrentRow.Cells[col].Value ?? "");
        g.CurrentRow.Cells[col].Value = string.IsNullOrWhiteSpace(cur) ? picked : (cur.TrimEnd(' ',';') + " ; " + picked);
    }

    // ---------- config load / save ----------
    static string S(object o) { return o == null ? "" : o.ToString(); }

    void LoadConfig() {
        try {
            if (!File.Exists(configPath)) { SetStatus("config.json not found — will create on Save", true); return; }
            var js = new JavaScriptSerializer();
            var root = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(configPath, Encoding.UTF8));
            object f;
            if (root.TryGetValue("ftp", out f) && f is Dictionary<string, object>) {
                var d = (Dictionary<string, object>)f;
                object v;
                if (d.TryGetValue("host", out v)) txtHost.Text = S(v);
                if (d.TryGetValue("port", out v)) txtPort.Text = S(v);
                if (d.TryGetValue("username", out v)) txtUser.Text = S(v);
                if (d.TryGetValue("password", out v)) txtPass.Text = S(v);
                if (d.TryGetValue("protocol", out v)) {
                    int i = cmbProtocol.FindStringExact(S(v));
                    cmbProtocol.SelectedIndex = i >= 0 ? i : 0;
                }
                if (d.TryGetValue("remoteRoot", out v)) txtRoot.Text = S(v);
                if (d.TryGetValue("passive", out v)) {
                    bool b = true;
                    try { b = Convert.ToBoolean(v); } catch { b = (S(v).ToLower() != "active" && S(v).ToLower() != "false"); }
                    chkPassive.Checked = b;
                }
                if (d.TryGetValue("timeoutSeconds", out v)) txtTimeout.Text = S(v);
            }
            gridRenames.Rows.Clear();
            foreach (var m in GetList(root, "renames")) {
                var a = GetStr(m, "remote_file_address", "remoteFileAddress", "source", "path");
                var b = GetStr(m, "remote_new_file_name", "remoteNewFileName", "newName", "target");
                if (a == "" && b == "") continue;
                gridRenames.Rows.Add(a, b);
            }
            gridRemoves.Rows.Clear();
            foreach (var m in GetList(root, "removes")) {
                if (m is string) { if (!string.IsNullOrWhiteSpace((string)m)) gridRemoves.Rows.Add((string)m); continue; }
                var a = GetStr(m, "remote_file_address", "remoteFileAddress", "path");
                if (a != "") gridRemoves.Rows.Add(a);
            }
            gridUploads.Rows.Clear();
            foreach (var m in GetList(root, "uploads")) {
                if (!(m is Dictionary<string, object>)) continue;
                var d = (Dictionary<string, object>)m;
                string files = JoinArr(GetVal(d, "local_file_address", "localFileAddress", "local_files", "files"));
                string folders = JoinArr(GetVal(d, "local_folder_address", "localFolderAddress", "local_folders", "folders"));
                string dest = S(GetVal(d, "remote_folder", "remoteFolder", "remoteDir", "target"));
                if (files == "" && folders == "" && dest == "") continue;
                gridUploads.Rows.Add(files, folders, dest);
            }
            SetStatus("loaded " + Path.GetFileName(configPath), false);
            Log("Loaded " + configPath);
        } catch (Exception ex) { SetStatus("load failed: " + ex.Message, true); Log("LOAD FAILED: " + ex); }
    }

    static ArrayList GetList(Dictionary<string, object> root, string key) {
        object o;
        if (!root.TryGetValue(key, out o) || o == null) return new ArrayList();
        if (o is ArrayList) return (ArrayList)o;
        return new ArrayList { o };
    }
    static object GetVal(Dictionary<string, object> d, params string[] keys) {
        foreach (var k in keys) { object v; if (d.TryGetValue(k, out v)) return v; }
        return null;
    }
    static string GetStr(object m, params string[] keys) {
        if (m is Dictionary<string, object>) {
            var d = (Dictionary<string, object>)m;
            foreach (var k in keys) { object v; if (d.TryGetValue(k, out v) && v != null && !string.IsNullOrWhiteSpace(v.ToString())) return v.ToString().Trim(); }
        }
        return "";
    }
    static string JoinArr(object v) {
        if (v == null) return "";
        if (v is string) return ((string)v).Trim();
        if (v is ArrayList) {
            var parts = new List<string>();
            foreach (var x in (ArrayList)v) if (x != null && !string.IsNullOrWhiteSpace(x.ToString())) parts.Add(x.ToString().Trim());
            return string.Join(" ; ", parts);
        }
        return v.ToString().Trim();
    }
    static ArrayList SplitArr(string s) {
        var list = new ArrayList();
        if (string.IsNullOrWhiteSpace(s)) return list;
        foreach (var p in s.Split(new char[] { ';', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)) {
            var t = p.Trim();
            if (t != "") list.Add(t);
        }
        return list;
    }
    static string Esc(string s) { return s.Replace("\\", "\\\\").Replace("\"", "\\\""); }

    void SaveConfig() {
        try {
            int port = 21, timeout = 60;
            int.TryParse(txtPort.Text.Trim(), out port);
            int.TryParse(txtTimeout.Text.Trim(), out timeout);
            var sb = new StringBuilder();
            sb.AppendLine("{");
            sb.AppendLine("  \"ftp\": {");
            sb.AppendLine("    \"host\": \"" + Esc(txtHost.Text.Trim()) + "\",");
            sb.AppendLine("    \"port\": " + port + ",");
            sb.AppendLine("    \"username\": \"" + Esc(txtUser.Text.Trim()) + "\",");
            sb.AppendLine("    \"password\": \"" + Esc(txtPass.Text) + "\",");
            sb.AppendLine("    \"protocol\": \"" + Esc(cmbProtocol.SelectedItem.ToString()) + "\",");
            sb.AppendLine("    \"remoteRoot\": \"" + Esc(txtRoot.Text.Trim()) + "\",");
            sb.AppendLine("    \"passive\": " + (chkPassive.Checked ? "true" : "false") + ",");
            sb.AppendLine("    \"timeoutSeconds\": " + timeout);
            sb.AppendLine("  },");
            sb.AppendLine("  \"renames\": [");
            bool first = true;
            foreach (DataGridViewRow r in gridRenames.Rows) {
                if (r.IsNewRow) continue;
                string a = Convert.ToString(r.Cells[0].Value ?? "").Trim();
                string b = Convert.ToString(r.Cells[1].Value ?? "").Trim();
                if (a == "" && b == "") continue;
                if (!first) sb.AppendLine(",");
                sb.Append("    { \"remote_file_address\": \"" + Esc(a) + "\", \"remote_new_file_name\": \"" + Esc(b) + "\" }");
                first = false;
            }
            sb.AppendLine(); sb.AppendLine("  ],");
            sb.AppendLine("  \"removes\": [");
            first = true;
            foreach (DataGridViewRow r in gridRemoves.Rows) {
                if (r.IsNewRow) continue;
                string a = Convert.ToString(r.Cells[0].Value ?? "").Trim();
                if (a == "") continue;
                if (!first) sb.AppendLine(",");
                sb.Append("    { \"remote_file_address\": \"" + Esc(a) + "\" }");
                first = false;
            }
            sb.AppendLine(); sb.AppendLine("  ],");
            sb.AppendLine("  \"uploads\": [");
            first = true;
            foreach (DataGridViewRow r in gridUploads.Rows) {
                if (r.IsNewRow) continue;
                string f = Convert.ToString(r.Cells[0].Value ?? "").Trim();
                string d = Convert.ToString(r.Cells[1].Value ?? "").Trim();
                string t = Convert.ToString(r.Cells[2].Value ?? "").Trim();
                if (f == "" && d == "" && t == "") continue;
                if (!first) sb.AppendLine(",");
                sb.Append("    { \"local_file_address\": [");
                var fl = SplitArr(f);
                for (int i = 0; i < fl.Count; i++) { if (i > 0) sb.Append(", "); sb.Append("\"" + Esc(fl[i].ToString()) + "\""); }
                sb.Append("], \"local_folder_address\": [");
                var dl = SplitArr(d);
                for (int i = 0; i < dl.Count; i++) { if (i > 0) sb.Append(", "); sb.Append("\"" + Esc(dl[i].ToString()) + "\""); }
                sb.Append("], \"remote_folder\": \"" + Esc(t) + "\" }");
                first = false;
            }
            sb.AppendLine(); sb.AppendLine("  ]");
            sb.AppendLine("}");
            File.WriteAllText(configPath, sb.ToString(), new UTF8Encoding(false));
            SetStatus("saved config.json ✔", false);
            Log("Saved " + configPath);
            MessageBox.Show("Saved to config.json", "Saved", MessageBoxButtons.OK, MessageBoxIcon.Information);
        } catch (Exception ex) { SetStatus("save failed", true); MessageBox.Show(ex.Message, "Save failed", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    void SetStatus(string t, bool isErr) {
        lblStatus.Text = t;
        lblStatus.ForeColor = isErr ? RED : Color.FromArgb(140, 255, 170);
    }
    void Log(string line) {
        if (txtLog.InvokeRequired) { txtLog.Invoke(new Action<string>(Log), line); return; }
        txtLog.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + line + Environment.NewLine);
    }

    void RunScript(bool dry) {
        try {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string ps1 = Path.Combine(dir, "FtpManager.ps1");
            if (!File.Exists(ps1)) { MessageBox.Show("FtpManager.ps1 not found next to exe.", "Missing", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
            btnRun.Enabled = false; btnDry.Enabled = false; btnSave.Enabled = false;
            SetStatus(dry ? "dry-run running…" : "deploy running…", false);
            Log((dry ? "DRYRUN: powershell -File FtpManager.ps1 -DryRun" : "RUN: powershell -File FtpManager.ps1"));
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + ps1 + "\"" + (dry ? " -DryRun" : "")) {
                WorkingDirectory = dir, UseShellExecute = false,
                RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true
            };
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (s, e) => { if (e.Data != null) Log(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) Log("ERR: " + e.Data); };
            p.Exited += (s, e) => {
                this.Invoke(new Action(() => {
                    btnRun.Enabled = true; btnDry.Enabled = true; btnSave.Enabled = true;
                    SetStatus("exit code " + p.ExitCode + (p.ExitCode == 0 ? " ✔" : " ✖"), p.ExitCode != 0);
                    Log("Exit code: " + p.ExitCode);
                    p.Dispose();
                }));
            };
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        } catch (Exception ex) {
            btnRun.Enabled = true; btnDry.Enabled = true; btnSave.Enabled = true;
            MessageBox.Show(ex.Message, "Run failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    [STAThread]
    public static void Main() {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new ConfigEditorForm());
    }
}
