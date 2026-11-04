import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.regex.Pattern;
import java.util.zip.*;

/**
 * CSV -> XLSX converter. No dependencies (JDK 11+).
 * Usage: java CsvToXlsx.java input.csv [output.xlsx] [--delimiter=;]
 *        java CsvToXlsx.java --test
 */
public class CsvToXlsx {

    // Plain numbers only; leading zeros (zip codes, IDs) and >15 digits stay text so Excel doesn't mangle them.
    private static final Pattern NUMBER = Pattern.compile("-?(0|[1-9]\\d{0,14})(\\.\\d+)?([eE][+-]?\\d+)?");

    public static void main(String[] args) throws IOException {
        if (args.length == 1 && args[0].equals("--test")) { selfTest(); return; }
        char delim = ',';
        List<String> files = new ArrayList<>();
        for (String a : args) {
            if (a.startsWith("--delimiter=")) {
                String d = a.substring(12);
                delim = d.equals("\\t") ? '\t' : d.charAt(0);
            } else files.add(a);
        }
        if (files.isEmpty() || files.size() > 2) {
            System.err.println("Usage: java CsvToXlsx.java input.csv [output.xlsx] [--delimiter=;]");
            System.exit(1);
        }
        Path in = Paths.get(files.get(0));
        Path out = Paths.get(files.size() == 2 ? files.get(1)
                : files.get(0).replaceFirst("(?i)\\.csv$", "") + ".xlsx");

        String text = Files.readString(in, StandardCharsets.UTF_8);
        if (text.startsWith("﻿")) text = text.substring(1);
        List<List<String>> rows = parseCsv(text, delim);
        writeXlsx(rows, out);
        System.out.println("Wrote " + rows.size() + " rows to " + out);
    }

    /** RFC 4180: quoted fields, "" escapes, delimiters and newlines inside quotes. */
    static List<List<String>> parseCsv(String s, char delim) {
        List<List<String>> rows = new ArrayList<>();
        List<String> row = new ArrayList<>();
        StringBuilder field = new StringBuilder();
        boolean quoted = false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (quoted) {
                if (c == '"') {
                    if (i + 1 < s.length() && s.charAt(i + 1) == '"') { field.append('"'); i++; }
                    else quoted = false;
                } else field.append(c);
            } else if (c == '"') quoted = true;
            else if (c == delim) { row.add(field.toString()); field.setLength(0); }
            else if (c == '\n' || c == '\r') {
                if (c == '\r' && i + 1 < s.length() && s.charAt(i + 1) == '\n') i++;
                row.add(field.toString()); field.setLength(0);
                rows.add(row); row = new ArrayList<>();
            } else field.append(c);
        }
        if (field.length() > 0 || !row.isEmpty()) { row.add(field.toString()); rows.add(row); }
        return rows;
    }

    static void writeXlsx(List<List<String>> rows, Path out) throws IOException {
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(out))) {
            put(zip, "[Content_Types].xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
                + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                + "</Types>");
            put(zip, "_rels/.rels",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
                + "</Relationships>");
            put(zip, "xl/workbook.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
                + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
                + "<sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>");
            put(zip, "xl/_rels/workbook.xml.rels",
                "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
                + "</Relationships>");

            zip.putNextEntry(new ZipEntry("xl/worksheets/sheet1.xml"));
            Writer w = new BufferedWriter(new OutputStreamWriter(zip, StandardCharsets.UTF_8));
            w.write("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>");
            for (int r = 0; r < rows.size(); r++) {
                w.write("<row r=\"" + (r + 1) + "\">");
                List<String> row = rows.get(r);
                for (int c = 0; c < row.size(); c++) {
                    String v = row.get(c);
                    if (v.isEmpty()) continue;
                    String ref = colName(c) + (r + 1);
                    if (NUMBER.matcher(v).matches())
                        w.write("<c r=\"" + ref + "\"><v>" + v + "</v></c>");
                    else
                        w.write("<c r=\"" + ref + "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">" + xml(v) + "</t></is></c>");
                }
                w.write("</row>");
            }
            w.write("</sheetData></worksheet>");
            w.flush();
            zip.closeEntry();
        }
    }

    private static void put(ZipOutputStream zip, String name, String content) throws IOException {
        zip.putNextEntry(new ZipEntry(name));
        zip.write(content.getBytes(StandardCharsets.UTF_8));
        zip.closeEntry();
    }

    /** 0 -> A, 25 -> Z, 26 -> AA */
    static String colName(int i) {
        StringBuilder sb = new StringBuilder();
        for (i++; i > 0; i = (i - 1) / 26) sb.insert(0, (char) ('A' + (i - 1) % 26));
        return sb.toString();
    }

    /** Escapes XML and drops control chars that are illegal in XML 1.0 (Excel refuses the file otherwise). */
    static String xml(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (char ch : s.toCharArray()) {
            switch (ch) {
                case '&': sb.append("&amp;"); break;
                case '<': sb.append("&lt;"); break;
                case '>': sb.append("&gt;"); break;
                case '"': sb.append("&quot;"); break;
                default: if (ch >= 0x20 || ch == '\t' || ch == '\n' || ch == '\r') sb.append(ch);
            }
        }
        return sb.toString();
    }

    static void selfTest() {
        check(parseCsv("a,b\r\n1,2\n", ',').toString(), "[[a, b], [1, 2]]");
        check(parseCsv("\"x,y\",\"say \"\"hi\"\"\"\n", ',').toString(), "[[x,y, say \"hi\"]]");
        check(parseCsv("\"line1\nline2\",z", ',').toString(), "[[line1\nline2, z]]");
        check(parseCsv("a;;c", ';').toString(), "[[a, , c]]");
        check(colName(0) + colName(25) + colName(26) + colName(701) + colName(702), "AZAAZZAAA");
        check(xml("a<b>&\u0001"), "a&lt;b&gt;&amp;");
        check("" + NUMBER.matcher("3.14").matches() + NUMBER.matcher("-2e5").matches()
                + NUMBER.matcher("00123").matches() + NUMBER.matcher("1234567890123456").matches(),
              "truetruefalsefalse");
        System.out.println("All tests passed");
    }

    private static void check(String got, String want) {
        if (!got.equals(want)) throw new AssertionError("expected <" + want + "> got <" + got + ">");
    }
}
