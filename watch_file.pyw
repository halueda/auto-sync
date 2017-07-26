"""
Usage: pythonw.exe $0 filename

ファイルの更新日時を監視し、一定以上（ハードコーディング１０分）更新がないと色が変わるGUIアプリ。
  最近更新されていれば　緑
　更新が止まっていれば　赤
　ファイルの監視でエラー黄

GUI中にはファイルの最後3行分を表示

監視インターバルは10秒毎（ハードコーディング）

ファイルのエンコーディングは、UTF8（ハードコーディング）

"""
import tkinter as tk
import sys
from threading import Timer
import datetime
import os

#filename = 'D:/tmp/test'
#filename = '//nas.kawasaki.flab.fujitsu.co.jp/ueda/09-tmp/sync_statuslog'

if len(sys.argv) ==2:
  filename = sys.argv[1]
else:
  filename = "No filename specified. Usage: pythonw.exe %s filename" % sys.argv[0]


class RepeatedTimer(Timer):
  def __init__(self, interval, function, args=[], kwargs={}):
    Timer.__init__(self, interval, self.run, args, kwargs)
    self.thread = None
    self.function = function

  def run(self):
    self.thread = Timer(self.interval, self.run)
    self.thread.start()
    self.function(*self.args, **self.kwargs)

  def cancel(self):
    if self.thread is not None:
      self.thread.cancel()
      self.thread.join()
      del self.thread


class Application(tk.Frame):

    def update(self):
        try:
            dt = datetime.datetime.fromtimestamp(os.stat(filename).st_mtime)
            #現在時刻より10分以上前なら赤、それ以外なら緑にする
            if datetime.datetime.now() - dt > datetime.timedelta(minutes=10) :
#            if datetime.datetime.now() - dt > datetime.timedelta(seconds=10) :
                self.body["bg"] = "salmon"
            else:
                self.body["bg"] = "lawngreen"
            if dt > self.update_dt:
                #ファイルの最後３行をボタンに表示
                # エンコーディングをここで指定。
                with open(filename, encoding='UTF8', errors='ignore') as f:
                    lines = f.readlines()
                    self.body["text"] = "".join(lines[-3:])
                    self.update_dt = dt
        except Exception as e:
            self.body["bg"] = "yellow"
            self.body["text"] = str(e)
#        デバッグ用
#        self.counter += 1
#        print( "update %d" % self.counter )
#        sys.stdout.flush()
#        sys.stderr.flush()

    def createWidgets(self):
#        self.body = tk.Label(self, text="", width=80, justify=tk.LEFT)
#        self.body = tk.Label(self, text="", width=80, wraplength=80, justify=tk.LEFT)
#        self.body = tk.Message(self, text="", justify=tk.LEFT)
        self.body = tk.Message(self, text="", width=300, justify=tk.LEFT)
        self.body.pack(fill=tk.BOTH, expand=True)

        self.update_dt = datetime.datetime.min

    def __init__(self, master=None):
        tk.Frame.__init__(self, master)
        self.pack(fill=tk.BOTH, expand=True)
        self.createWidgets()
#        self.counter=0

global root, app, r_timer

def quit():
    r_timer.cancel()
    app.quit()

if __name__=='__main__':    
    root = tk.Tk()
    app = Application(master=root)
    root.title("watch file")
    root.protocol("WM_DELETE_WINDOW", quit)
    r_timer = RepeatedTimer(10, app.update, [])
    r_timer.start()
    app.mainloop()
    root.destroy()
