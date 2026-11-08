// 程序备注：右键程序 → "写备注说明"。存在 notes.json（只在本机，不上传），会替换"说明"列里的默认说明
using System;
using System.Collections.Generic;
using System.IO;

namespace WatchDog
{
    partial class Monitor
    {
        Dictionary<string, string> notes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string NotesPath { get { return Path.Combine(RulesDir, "notes.json"); } }

        void LoadNotes()
        {
            Dictionary<string, string> m = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (File.Exists(NotesPath))
                {
                    Dictionary<string, object> d = Json.Parse(Json.ReadFile(NotesPath)) as Dictionary<string, object>;
                    if (d != null) foreach (KeyValuePair<string, object> kv in d) if (kv.Value is string && ((string)kv.Value).Length > 0) m[kv.Key] = (string)kv.Value;
                }
            }
            catch { }
            notes = m;
        }
        void SaveNotes()
        {
            Dictionary<string, object> d = new Dictionary<string, object>();
            foreach (KeyValuePair<string, string> kv in notes) d[kv.Key] = kv.Value;
            try { Json.WriteFile(NotesPath, d); } catch (Exception ex) { Say("备注没能保存：" + ex.Message); }
        }

        // 说明：自己写的备注优先，其次是内置的中文说明
        string DescOf(string name)
        {
            string s;
            if (name == null) return null;
            if (notes.TryGetValue(name, out s)) return s;
            return Desc.TryGetValue(name, out s) ? s : null;
        }
        bool HasNote(string name) { return name != null && notes.ContainsKey(name); }

        void EditNote(string name)
        {
            if (name == null) return;
            string cur; notes.TryGetValue(name, out cur);
            string def; Desc.TryGetValue(name, out def);
            string ans = Microsoft.VisualBasic.Interaction.InputBox(
                "给「" + name + "」写一句备注（会显示在\"说明\"列里）。\n\n" + (def != null ? "默认说明：" + def + "\n" : "") + "留空并确定 = 删除备注，恢复默认说明。",
                "WATCHDOG // 备注", cur ?? def ?? "");
            if (ans == null) return;
            ans = ans.Trim();
            if (ans.Length == 0 && cur == null) return;   // 取消（InputBox 取消时也返回空）
            if (ans.Length == 0 || ans == def) notes.Remove(name); else notes[name] = ans.Length > 60 ? ans.Substring(0, 60) : ans;
            SaveNotes();
            RefreshAll();
        }
    }
}
