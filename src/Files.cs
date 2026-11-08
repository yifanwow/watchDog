// 文件读写：JSON（规则、忽略记录）和 CSV（看门狗的历史记录）
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace WatchDog
{
    static class Json
    {
        // 读：对象 = Dictionary<string, object>，数组 = object[]
        public static object Parse(string text)
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            js.MaxJsonLength = 16 * 1024 * 1024;
            return js.DeserializeObject(text);
        }

        // 把"一个对象或对象数组"统一拆成对象列表
        public static List<Dictionary<string, object>> Objects(object o)
        {
            List<Dictionary<string, object>> list = new List<Dictionary<string, object>>();
            Dictionary<string, object> d = o as Dictionary<string, object>;
            if (d != null) { list.Add(d); return list; }
            IEnumerable e = o as IEnumerable;
            if (e != null && !(o is string)) foreach (object x in e) { Dictionary<string, object> dx = x as Dictionary<string, object>; if (dx != null) list.Add(dx); }
            return list;
        }

        public static Dictionary<string, object> Obj(Dictionary<string, object> d, string key)
        {
            object o; return d != null && d.TryGetValue(key, out o) ? o as Dictionary<string, object> : null;
        }
        public static string Str(Dictionary<string, object> d, string key)
        {
            object o; if (d == null || !d.TryGetValue(key, out o) || o == null) return null;
            string s = Convert.ToString(o, CultureInfo.InvariantCulture);
            return s.Length == 0 ? null : s;
        }
        public static double Num(Dictionary<string, object> d, string key)
        {
            object o; if (d == null || !d.TryGetValue(key, out o) || o == null) return 0;
            try { return Convert.ToDouble(o, CultureInfo.InvariantCulture); } catch { return 0; }
        }
        public static bool Bool(Dictionary<string, object> d, string key)
        {
            object o; if (d == null || !d.TryGetValue(key, out o) || o == null) return false;
            if (o is bool) return (bool)o;
            return string.Equals(Convert.ToString(o), "true", StringComparison.OrdinalIgnoreCase);
        }

        // 写：带缩进，方便用记事本编辑。保持字段原来的顺序
        public static string Write(object o)
        {
            StringBuilder sb = new StringBuilder();
            WriteValue(sb, o, 0);
            return sb.ToString();
        }
        static void Indent(StringBuilder sb, int n) { sb.Append('\n'); sb.Append(' ', n * 4); }
        static void WriteValue(StringBuilder sb, object o, int depth)
        {
            if (o == null) { sb.Append("null"); return; }
            if (o is string) { WriteString(sb, (string)o); return; }
            if (o is bool) { sb.Append((bool)o ? "true" : "false"); return; }
            if (o is int || o is long || o is double || o is decimal || o is float)
            { sb.Append(Convert.ToString(o, CultureInfo.InvariantCulture)); return; }
            IDictionary<string, object> d = o as IDictionary<string, object>;
            if (d != null)
            {
                if (d.Count == 0) { sb.Append("{}"); return; }
                sb.Append('{'); bool first = true;
                foreach (KeyValuePair<string, object> kv in d)
                {
                    if (!first) sb.Append(',');
                    first = false; Indent(sb, depth + 1);
                    WriteString(sb, kv.Key); sb.Append(": "); WriteValue(sb, kv.Value, depth + 1);
                }
                Indent(sb, depth); sb.Append('}'); return;
            }
            IEnumerable e = o as IEnumerable;
            if (e != null)
            {
                List<object> items = new List<object>(); foreach (object x in e) items.Add(x);
                if (items.Count == 0) { sb.Append("[]"); return; }
                sb.Append('[');
                for (int i = 0; i < items.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    Indent(sb, depth + 1); WriteValue(sb, items[i], depth + 1);
                }
                Indent(sb, depth); sb.Append(']'); return;
            }
            WriteString(sb, Convert.ToString(o, CultureInfo.InvariantCulture));
        }
        static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default: if (c < 0x20) sb.AppendFormat("\\u{0:x4}", (int)c); else sb.Append(c); break;
                }
            }
            sb.Append('"');
        }

        public static string ReadFile(string path) { return File.ReadAllText(path, Encoding.UTF8); }
        public static void WriteFile(string path, object o) { File.WriteAllText(path, Write(o), new UTF8Encoding(false)); }
    }

    static class Csv
    {
        // PowerShell Export-Csv 的格式：第一行是列名，每个字段都带引号。返回每行一个"列名 -> 值"
        public static List<Dictionary<string, string>> Read(string path)
        {
            List<Dictionary<string, string>> rows = new List<Dictionary<string, string>>();
            string[] lines;
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
                    lines = sr.ReadToEnd().Split('\n');
            }
            catch { return rows; }
            List<string> head = null;
            foreach (string raw in lines)
            {
                string line = raw.TrimEnd('\r');
                if (line.Length == 0 || line.StartsWith("#")) continue;
                List<string> f = Split(line);
                if (head == null) { head = f; continue; }
                // 追加写入时如果列变了，PowerShell 会再写一行列名
                if (f.Count > 0 && f[0] == head[0]) { head = f; continue; }
                Dictionary<string, string> d = new Dictionary<string, string>();
                for (int i = 0; i < head.Count && i < f.Count; i++) d[head[i]] = f[i];
                rows.Add(d);
            }
            return rows;
        }
        static List<string> Split(string line)
        {
            List<string> f = new List<string>(); StringBuilder cur = new StringBuilder(); bool q = false;
            for (int i = 0; i < line.Length; i++)
            {
                char c = line[i];
                if (q)
                {
                    if (c == '"') { if (i + 1 < line.Length && line[i + 1] == '"') { cur.Append('"'); i++; } else q = false; }
                    else cur.Append(c);
                }
                else if (c == '"') q = true;
                else if (c == ',') { f.Add(cur.ToString()); cur.Length = 0; }
                else cur.Append(c);
            }
            f.Add(cur.ToString());
            return f;
        }
        public static double Num(Dictionary<string, string> d, string key, double def)
        {
            string s; double v;
            if (d.TryGetValue(key, out s) && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
            // 历史文件按系统区域格式写数字（比如小数点是逗号）也能读
            if (s != null && double.TryParse(s, NumberStyles.Float, CultureInfo.CurrentCulture, out v)) return v;
            return def;
        }
        public static bool Has(Dictionary<string, string> d, string key) { string s; return d.TryGetValue(key, out s) && s.Length > 0; }
    }
}
