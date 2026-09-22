"""ناشر لوحة المدير — اسحب وأفلت.

يُشغَّل بالنقر المزدوج (لاحقة `.pyw` تعني بلا نافذة سوداء خلفه).

**لماذا أداةٌ لا أمرٌ في الطرفية؟** لأن الأمر يُنسى بين نشرٍ وآخر:
مسار المجلّد، واسم المشروع، والفرع، و`npx.cmd` بلاحقتها. ونسيان جزءٍ
منها يُنتج نشراً إلى مشروعٍ خاطئ أو رسالةَ خطأٍ تُحبط. والأداة تحفظها
كلها.

**ولماذا تقبل المجلّد كما تقبل الـZIP؟** لأن الضغط خطوةٌ زائدة حين
يكون المجلّد جاهزاً على القرص. و`wrangler` يرفع الملفات لا الأرشيف،
فنحن نفكّ ما تضغطه ثم نرفعه — فلماذا الضغط أصلاً؟
"""

import os
import queue
import shutil
import subprocess
import tempfile
import threading
import tkinter as tk
import webbrowser
import zipfile
from pathlib import Path
from tkinter import filedialog, ttk

try:
    from tkinterdnd2 import DND_FILES, TkinterDnD
    HAS_DND = True
except ImportError:      # الأداة تعمل بلا السحب، بزرّ الاختيار وحده.
    HAS_DND = False

# ---------------------------------------------------------------------------
# ثوابت المشروع
# ---------------------------------------------------------------------------
PROJECT = "zanbour-admin"
BRANCH = "main"
URL = f"https://{PROJECT}.pages.dev"

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUILD = ROOT / "apps" / "admin" / "build" / "web"

BG = "#1c1a16"
FG = "#f2ece2"
DIM = "#9a9186"
GOLD = "#d9a441"
OK = "#5db85c"
BAD = "#d9534f"


def merged_path() -> str:
    """مسارات النظام والمستخدم معاً.

    **نافذةٌ فُتحت قبل تثبيت Node لا تعرفه.** هذا ما أوقفنا مرتين:
    الأداة قد تُشغَّل من صدفةٍ قديمة، فنقرأ المسار من السجلّ لا من
    البيئة الموروثة.
    """
    if os.name != "nt":
        return os.environ.get("PATH", "")
    try:
        import winreg

        parts = []
        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
        ) as k:
            parts.append(winreg.QueryValueEx(k, "Path")[0])
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            parts.append(winreg.QueryValueEx(k, "Path")[0])
        return ";".join(p for p in parts if p)
    except OSError:
        return os.environ.get("PATH", "")


def npx_path() -> str:
    """المسار الكامل لـ`npx` — لا اسمه المجرّد.

    **ويندوز يبحث عن البرنامج في مسار العملية الأمّ لا في البيئة التي
    نمرّرها للابن.** فأداةٌ تُشغَّل من صدفةٍ فُتحت قبل تثبيت Node تقول
    «لم يُعثر على npx» مهما صحّحنا `env["PATH"]` — وقد وقع ذلك في أول
    تشغيلٍ لهذه الأداة نفسها.

    **و`npx.cmd` لا `npx`:** سياسة PowerShell تمنع سكربتات `.ps1`،
    و`.cmd` ملفّ أوامر لا يمرّ عليها.
    """
    name = "npx.cmd" if os.name == "nt" else "npx"
    found = shutil.which(name, path=merged_path())
    return found or name


class App:
    def __init__(self, root):
        self.root = root
        self.busy = False
        self.lines = queue.Queue()
        self.tmp = None

        root.title("نشر لوحة زنبور")
        root.geometry("640x520")
        root.configure(bg=BG)

        tk.Label(
            root, text="ناشر لوحة المدير", bg=BG, fg=FG,
            font=("Segoe UI", 16, "bold"),
        ).pack(pady=(18, 2))

        tk.Label(
            root, text=URL, bg=BG, fg=GOLD, font=("Consolas", 10),
            cursor="hand2",
        ).pack()

        # ---- منطقة الإفلات ----
        self.drop = tk.Label(
            root,
            text=(
                "اسحب هنا ملفّ web.zip\nأو مجلّد build/web"
                if HAS_DND
                else "اضغط «اختر ملفاً» أدناه"
            ),
            bg="#262218", fg=DIM, font=("Segoe UI", 12),
            relief="ridge", bd=2, height=5,
        )
        self.drop.pack(fill="x", padx=20, pady=16)

        if HAS_DND:
            self.drop.drop_target_register(DND_FILES)
            self.drop.dnd_bind("<<Drop>>", self.on_drop)

        # ---- الأزرار ----
        row = tk.Frame(root, bg=BG)
        row.pack(fill="x", padx=20)

        # **الزرّ الأول هو الحالة الشائعة.** في تسعٍ من عشر مرات يكون
        # آخر بناءٍ هو المطلوب، فلا معنى لأن يبحث عنه في القرص.
        self.btn_last = tk.Button(
            row, text="انشر آخر بناء", command=self.deploy_last,
            bg=GOLD, fg="#1c1a16", font=("Segoe UI", 11, "bold"),
            relief="flat", padx=14, pady=8, cursor="hand2",
        )
        self.btn_last.pack(side="right")

        self.btn_pick = tk.Button(
            row, text="اختر ملفاً…", command=self.pick,
            bg="#3a3428", fg=FG, font=("Segoe UI", 11),
            relief="flat", padx=14, pady=8, cursor="hand2",
        )
        self.btn_pick.pack(side="right", padx=8)

        tk.Button(
            row, text="افتح اللوحة", command=lambda: webbrowser.open(URL),
            bg="#3a3428", fg=FG, font=("Segoe UI", 11),
            relief="flat", padx=14, pady=8, cursor="hand2",
        ).pack(side="left")

        # ---- السجلّ ----
        self.status = tk.Label(
            root, text="جاهز", bg=BG, fg=DIM, font=("Segoe UI", 10),
        )
        self.status.pack(pady=(14, 4))

        self.bar = ttk.Progressbar(root, mode="indeterminate")

        self.log = tk.Text(
            root, height=10, bg="#141210", fg="#c9c2b6",
            font=("Consolas", 9), relief="flat", wrap="word",
        )
        self.log.pack(fill="both", expand=True, padx=20, pady=(4, 18))
        self.log.configure(state="disabled")

        root.after(120, self.drain)

    # -----------------------------------------------------------------
    def say(self, text, color=DIM):
        self.status.configure(text=text, fg=color)

    def write(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def drain(self):
        """**الخيط لا يلمس الواجهة.** tkinter ليس آمناً بين الخيوط،
        والكتابة فيه من خيطٍ آخر تُجمّد النافذة أو تُسقطها."""
        try:
            while True:
                kind, payload = self.lines.get_nowait()
                if kind == "log":
                    self.write(payload)
                elif kind == "status":
                    self.say(payload[0], payload[1])
                elif kind == "done":
                    self.finish(payload)
        except queue.Empty:
            pass
        self.root.after(120, self.drain)

    # -----------------------------------------------------------------
    def on_drop(self, event):
        raw = event.data.strip()
        # ويندوز يُحيط المسار الذي فيه فراغات بأقواس معقوفة.
        if raw.startswith("{") and raw.endswith("}"):
            raw = raw[1:-1]
        self.start(Path(raw))

    def pick(self):
        p = filedialog.askopenfilename(
            title="اختر web.zip",
            filetypes=[("أرشيف مضغوط", "*.zip"), ("كل الملفات", "*.*")],
        )
        if p:
            self.start(Path(p))

    def deploy_last(self):
        if not DEFAULT_BUILD.exists():
            self.say("لا يوجد بناءٌ سابق — ابنِ اللوحة أولاً", BAD)
            return
        self.start(DEFAULT_BUILD)

    # -----------------------------------------------------------------
    def start(self, path: Path):
        if self.busy:
            return
        if not path.exists():
            self.say("المسار غير موجود", BAD)
            return

        self.busy = True
        self.btn_last.configure(state="disabled")
        self.btn_pick.configure(state="disabled")
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        self.bar.pack(fill="x", padx=20, pady=(0, 6))
        self.bar.start(12)
        self.say("جارٍ النشر…", GOLD)

        threading.Thread(target=self.run, args=(path,), daemon=True).start()

    def run(self, path: Path):
        try:
            folder = self.prepare(path)
            if folder is None:
                return

            # **الفحص قبل الرفع.** مجلّدٌ بلا `index.html` ليس بناءً —
            # ورفعه يُنتج لوحةً بيضاء بلا رسالة خطأ واحدة.
            if not (folder / "index.html").exists():
                self.lines.put(("done", ("لا يوجد index.html — ليس بناء لوحة", False)))
                return

            if not (folder / "_redirects").exists():
                self.lines.put((
                    "log",
                    "تنبيه: لا يوجد _redirects — ستنكسر الروابط الداخلية\n\n",
                ))

            env = dict(os.environ)
            env["PATH"] = merged_path()

            cmd = [
                npx_path(), "--yes", "wrangler@latest", "pages", "deploy",
                str(folder),
                "--project-name", PROJECT,
                "--branch", BRANCH,
                "--commit-dirty=true",
            ]

            self.lines.put(("log", f"{' '.join(cmd[:5])} …\n\n"))

            proc = subprocess.Popen(
                cmd, cwd=str(ROOT), env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
                creationflags=(
                    subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
                ),
            )

            for line in proc.stdout:
                self.lines.put(("log", line))

            code = proc.wait()
            self.lines.put(("done", (
                "تمّ النشر ✓" if code == 0 else f"فشل النشر (رمز {code})",
                code == 0,
            )))

        except FileNotFoundError:
            self.lines.put(("done", ("لم يُعثر على npx — ثبّت Node.js", False)))
        except Exception as e:                      # noqa: BLE001
            self.lines.put(("log", f"\n{e}\n"))
            self.lines.put(("done", ("خطأ غير متوقّع", False)))
        finally:
            self.cleanup()

    def prepare(self, path: Path):
        """يفكّ الـZIP إن لزم، ويعيد المجلّد الذي يُرفع."""
        if path.is_dir():
            return path

        if path.suffix.lower() != ".zip":
            self.lines.put(("done", ("اسحب مجلّداً أو ملفّ .zip", False)))
            return None

        self.tmp = Path(tempfile.mkdtemp(prefix="zanbour-web-"))
        self.lines.put(("log", "جارٍ فكّ الضغط…\n"))
        with zipfile.ZipFile(path) as z:
            z.extractall(self.tmp)

        # **بعض الأرشيفات تحوي مجلّداً واحداً يلفّ كل شيء.** فنغوص
        # إليه، وإلا رفعنا مجلّداً فارغاً إلا من مجلّد.
        if not (self.tmp / "index.html").exists():
            subs = [d for d in self.tmp.iterdir() if d.is_dir()]
            if len(subs) == 1 and (subs[0] / "index.html").exists():
                return subs[0]

        return self.tmp

    def cleanup(self):
        if self.tmp and self.tmp.exists():
            shutil.rmtree(self.tmp, ignore_errors=True)
        self.tmp = None

    def finish(self, payload):
        text, ok = payload
        self.busy = False
        self.bar.stop()
        self.bar.pack_forget()
        self.btn_last.configure(state="normal")
        self.btn_pick.configure(state="normal")
        self.say(text, OK if ok else BAD)
        if ok:
            self.write(f"\n{URL}\n")


def main():
    root = TkinterDnD.Tk() if HAS_DND else tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
