package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type config struct {
	Addr         string
	User         string
	PasswordSalt string
	PasswordHash string
	APIURL       string
	FilesURL     string
	NotesHTTPS   string
	FilesHTTPS   string
	ProjectDir   string
	BackupDir    string
	LogFilesCSV  string
}

type app struct {
	cfg    config
	client *http.Client
	tpl    *template.Template
}

type probe struct {
	Name       string `json:"name"`
	URL        string `json:"url"`
	State      string `json:"state"`
	Detail     string `json:"detail"`
	HTTPStatus int    `json:"http_status,omitempty"`
	LatencyMS  int64  `json:"latency_ms"`
}

type backupStatus struct {
	Found     bool   `json:"found"`
	CreatedAt string `json:"created_at,omitempty"`
	File      string `json:"file,omitempty"`
	SHA256    string `json:"sha256,omitempty"`
	SizeBytes int64  `json:"size_bytes,omitempty"`
	Hostname  string `json:"hostname,omitempty"`
	Detail    string `json:"detail,omitempty"`
}

type logBlock struct {
	Path    string   `json:"path"`
	ModTime string   `json:"mod_time,omitempty"`
	Lines   []string `json:"lines"`
	Error   string   `json:"error,omitempty"`
}

type dashboardData struct {
	GeneratedAt string       `json:"generated_at"`
	Overall     string       `json:"overall"`
	Probes      []probe      `json:"probes"`
	Backup      backupStatus `json:"backup"`
	Logs        []logBlock   `json:"logs"`
}

func main() {
	cfg := config{
		Addr:         env("SN_DASHBOARD_ADDR", "127.0.0.1:8090"),
		User:         env("SN_DASHBOARD_USER", "admin"),
		PasswordSalt: env("SN_DASHBOARD_PASSWORD_SALT", ""),
		PasswordHash: env("SN_DASHBOARD_PASSWORD_SHA256", ""),
		APIURL:       env("SN_DASHBOARD_API_URL", "http://127.0.0.1:3000"),
		FilesURL:     env("SN_DASHBOARD_FILES_URL", "http://127.0.0.1:3125"),
		NotesHTTPS:   env("SN_DASHBOARD_NOTES_HTTPS", ""),
		FilesHTTPS:   env("SN_DASHBOARD_FILES_HTTPS", ""),
		ProjectDir:   env("SN_PROJECT_DIR", "/opt/standardnotes"),
		BackupDir:    env("SN_BACKUP_DIR", "/opt/standardnotes/backups"),
		LogFilesCSV:  env("SN_DASHBOARD_LOG_FILES", "/var/log/nginx/standardnotes-error.log,/var/log/nginx/standardnotes-files-error.log,/opt/standardnotes/logs/*.err"),
	}
	if cfg.PasswordSalt == "" || cfg.PasswordHash == "" {
		log.Fatal("SN_DASHBOARD_PASSWORD_SALT and SN_DASHBOARD_PASSWORD_SHA256 must be set")
	}

	tpl := template.Must(template.New("dashboard").Funcs(template.FuncMap{
		"bytes": formatBytes,
		"join":  strings.Join,
	}).Parse(pageTemplate))

	a := &app{
		cfg: cfg,
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
		tpl: tpl,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.Handle("/api/status", a.requireAuth(http.HandlerFunc(a.statusJSON)))
	mux.Handle("/", a.requireAuth(http.HandlerFunc(a.index)))

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           securityHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("Standard Notes dashboard listening on %s", cfg.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (a *app) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || !a.validCredentials(user, pass) {
			w.Header().Set("WWW-Authenticate", `Basic realm="Standard Notes dashboard", charset="UTF-8"`)
			http.Error(w, "authentication required", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *app) validCredentials(user, pass string) bool {
	userOK := subtle.ConstantTimeCompare([]byte(user), []byte(a.cfg.User)) == 1
	sum := sha256.Sum256([]byte(a.cfg.PasswordSalt + ":" + pass))
	hash := hex.EncodeToString(sum[:])
	passOK := subtle.ConstantTimeCompare([]byte(hash), []byte(a.cfg.PasswordHash)) == 1
	return userOK && passOK
}

func (a *app) index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := a.tpl.Execute(w, a.collect()); err != nil {
		log.Printf("template error: %v", err)
	}
}

func (a *app) statusJSON(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(a.collect())
}

func (a *app) collect() dashboardData {
	probes := []probe{
		a.checkURL("Local API", a.cfg.APIURL),
		a.checkURL("Local files server", a.cfg.FilesURL),
	}
	if a.cfg.NotesHTTPS != "" {
		probes = append(probes, a.checkURL("Public notes HTTPS", a.cfg.NotesHTTPS))
	}
	if a.cfg.FilesHTTPS != "" {
		probes = append(probes, a.checkURL("Public files HTTPS", a.cfg.FilesHTTPS))
	}

	backup := readBackupStatus(a.cfg.BackupDir)
	logs := collectLogs(a.cfg.LogFilesCSV, 6, 60)
	overall := "ok"
	for _, p := range probes {
		if p.State == "down" {
			overall = "down"
			break
		}
		if p.State == "warn" && overall == "ok" {
			overall = "warn"
		}
	}
	if !backup.Found && overall == "ok" {
		overall = "warn"
	}

	return dashboardData{
		GeneratedAt: time.Now().Format(time.RFC3339),
		Overall:     overall,
		Probes:      probes,
		Backup:      backup,
		Logs:        logs,
	}
}

func (a *app) checkURL(name, url string) probe {
	start := time.Now()
	p := probe{Name: name, URL: url, State: "down"}
	if strings.TrimSpace(url) == "" {
		p.State = "warn"
		p.Detail = "not configured"
		return p
	}

	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		p.Detail = err.Error()
		return p
	}
	req.Header.Set("User-Agent", "standardnotes-dashboard/1.0")
	resp, err := a.client.Do(req)
	p.LatencyMS = time.Since(start).Milliseconds()
	if err != nil {
		p.Detail = err.Error()
		return p
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))

	p.HTTPStatus = resp.StatusCode
	p.Detail = resp.Status
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 400:
		p.State = "ok"
	case resp.StatusCode >= 400 && resp.StatusCode < 500:
		// Some Standard Notes endpoints return 404/401 at root while the service is reachable.
		p.State = "warn"
	default:
		p.State = "down"
	}
	return p
}

func readBackupStatus(dir string) backupStatus {
	latest := filepath.Join(dir, "LATEST.json")
	data, err := os.ReadFile(latest)
	if err == nil {
		var b backupStatus
		if json.Unmarshal(data, &b) == nil {
			b.Found = true
			return b
		}
	}

	matches, _ := filepath.Glob(filepath.Join(dir, "standardnotes-backup-*.tar.gz"))
	if len(matches) == 0 {
		return backupStatus{Found: false, Detail: "No backup has been recorded yet"}
	}
	sort.Slice(matches, func(i, j int) bool {
		a, _ := os.Stat(matches[i])
		b, _ := os.Stat(matches[j])
		if a == nil || b == nil {
			return matches[i] > matches[j]
		}
		return a.ModTime().After(b.ModTime())
	})
	info, err := os.Stat(matches[0])
	if err != nil {
		return backupStatus{Found: false, Detail: err.Error()}
	}
	return backupStatus{
		Found:     true,
		CreatedAt: info.ModTime().UTC().Format(time.RFC3339),
		File:      matches[0],
		SizeBytes: info.Size(),
		Detail:    "Derived from newest archive; LATEST.json was not readable",
	}
}

func collectLogs(csv string, maxFiles, maxLines int) []logBlock {
	var paths []string
	seen := map[string]bool{}
	for _, pattern := range strings.Split(csv, ",") {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" {
			continue
		}
		matches, err := filepath.Glob(pattern)
		if err != nil || len(matches) == 0 {
			if _, statErr := os.Stat(pattern); statErr == nil {
				matches = []string{pattern}
			}
		}
		for _, match := range matches {
			if !seen[match] {
				seen[match] = true
				paths = append(paths, match)
			}
		}
	}

	sort.Slice(paths, func(i, j int) bool {
		a, _ := os.Stat(paths[i])
		b, _ := os.Stat(paths[j])
		if a == nil || b == nil {
			return paths[i] < paths[j]
		}
		return a.ModTime().After(b.ModTime())
	})
	if len(paths) > maxFiles {
		paths = paths[:maxFiles]
	}

	blocks := make([]logBlock, 0, len(paths))
	for _, path := range paths {
		lines, modTime, err := tailLines(path, maxLines, 160*1024)
		block := logBlock{Path: path, ModTime: modTime, Lines: lines}
		if err != nil {
			block.Error = err.Error()
		}
		blocks = append(blocks, block)
	}
	return blocks
}

func tailLines(path string, maxLines int, maxBytes int64) ([]string, string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, "", err
	}
	if info.IsDir() {
		return nil, info.ModTime().UTC().Format(time.RFC3339), fmt.Errorf("is a directory")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, info.ModTime().UTC().Format(time.RFC3339), err
	}
	defer file.Close()

	start := int64(0)
	if info.Size() > maxBytes {
		start = info.Size() - maxBytes
	}
	if _, err := file.Seek(start, io.SeekStart); err != nil {
		return nil, info.ModTime().UTC().Format(time.RFC3339), err
	}
	content, err := io.ReadAll(file)
	if err != nil {
		return nil, info.ModTime().UTC().Format(time.RFC3339), err
	}
	text := strings.TrimRight(string(content), "\n")
	if text == "" {
		return []string{"(empty)"}, info.ModTime().UTC().Format(time.RFC3339), nil
	}
	lines := strings.Split(text, "\n")
	if len(lines) > maxLines {
		lines = lines[len(lines)-maxLines:]
	}
	return lines, info.ModTime().UTC().Format(time.RFC3339), nil
}

func formatBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for value := n / unit; value >= unit; value /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

const pageTemplate = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="30">
  <title>Standard Notes health</title>
  <style>
    :root { color-scheme: light dark; --ok:#15803d; --warn:#b45309; --down:#b91c1c; --muted:#64748b; --card:#f8fafc; --border:#cbd5e1; }
    @media (prefers-color-scheme: dark) { :root { --card:#111827; --border:#334155; --muted:#94a3b8; } body { background:#020617; color:#e5e7eb; } }
    body { margin:0; font:16px/1.5 system-ui,-apple-system,Segoe UI,sans-serif; }
    header { padding:2rem; border-bottom:1px solid var(--border); }
    main { max-width:1100px; margin:0 auto; padding:2rem; }
    h1 { margin:0 0 .25rem; font-size:1.8rem; }
    h2 { margin-top:2rem; }
    .muted { color:var(--muted); }
    .badge { display:inline-block; border-radius:999px; padding:.25rem .7rem; color:white; font-weight:700; text-transform:uppercase; letter-spacing:.05em; font-size:.75rem; }
    .badge.ok { background:var(--ok); } .badge.warn { background:var(--warn); } .badge.down { background:var(--down); }
    .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:1rem; }
    .card { background:var(--card); border:1px solid var(--border); border-left-width:6px; border-radius:14px; padding:1rem; overflow-wrap:anywhere; }
    .card.ok { border-left-color:var(--ok); } .card.warn { border-left-color:var(--warn); } .card.down { border-left-color:var(--down); }
    .label { font-weight:700; margin-bottom:.35rem; }
    code, pre { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
    pre { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:1rem; overflow:auto; max-height:28rem; }
    .small { font-size:.9rem; }
    a { color:inherit; }
  </style>
</head>
<body>
  <header>
    <h1>Standard Notes health</h1>
    <div class="muted">Generated at {{.GeneratedAt}} · auto-refreshes every 30 seconds</div>
    <p>Overall status: <span class="badge {{.Overall}}">{{.Overall}}</span></p>
  </header>
  <main>
    <h2>Service checks</h2>
    <section class="grid">
      {{range .Probes}}
      <article class="card {{.State}}">
        <div class="label">{{.Name}} <span class="badge {{.State}}">{{.State}}</span></div>
        <div class="small muted">{{.URL}}</div>
        <div>{{.Detail}}{{if .HTTPStatus}} · HTTP {{.HTTPStatus}}{{end}} · {{.LatencyMS}}ms</div>
      </article>
      {{end}}
    </section>

    <h2>Latest backup</h2>
    {{if .Backup.Found}}
      <article class="card ok">
        <div class="label">Backup found</div>
        <div>Created: <strong>{{.Backup.CreatedAt}}</strong></div>
        <div>File: <code>{{.Backup.File}}</code></div>
        <div>Size: {{bytes .Backup.SizeBytes}}</div>
        {{if .Backup.SHA256}}<div>SHA256: <code>{{.Backup.SHA256}}</code></div>{{end}}
        {{if .Backup.Detail}}<div class="muted">{{.Backup.Detail}}</div>{{end}}
      </article>
    {{else}}
      <article class="card warn">
        <div class="label">No backup marker found</div>
        <div>{{.Backup.Detail}}</div>
      </article>
    {{end}}

    <h2>Recent logs</h2>
    {{if .Logs}}
      {{range .Logs}}
        <h3><code>{{.Path}}</code></h3>
        <div class="small muted">Modified: {{.ModTime}}</div>
        {{if .Error}}
          <pre>{{.Error}}</pre>
        {{else}}
          <pre>{{join .Lines "\n"}}</pre>
        {{end}}
      {{end}}
    {{else}}
      <article class="card warn">No readable log files matched the dashboard configuration.</article>
    {{end}}
  </main>
</body>
</html>`
