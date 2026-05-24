// lib/Faculty/faculty_view_attendance.dart

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

const Color kPrimary = Color(0xFF8B0A1A);
const Color kGold    = Color(0xFFFBC02D);
const Color kBg      = Color(0xFFFDF2F3);

enum _Period { week, month }

class FacultyViewAttendance extends StatefulWidget {
  const FacultyViewAttendance({super.key});
  @override
  State<FacultyViewAttendance> createState() => _FacultyViewAttendanceState();
}

class _FacultyViewAttendanceState extends State<FacultyViewAttendance> {
  final _db   = rtdb.FirebaseDatabase.instance;
  final _fs   = FirebaseFirestore.instance;

  // ── Filter state ─────────────────────────────────────────────
  String  _dept      = 'Computer Science';
  String  _sem       = '1st';
  String  _shift     = 'Morning';
  String  _subject   = '';
  _Period _period    = _Period.week;

  bool   _loading    = false;
  bool   _fetched    = false;
  String _error      = '';

  // ── Data ─────────────────────────────────────────────────────
  // students: [ {uid, name, regNo} ]
  List<Map<String, dynamic>> _students = [];
  // dates in range (sorted asc)
  List<String> _dates = [];
  // attendance: { uid: { date: 'P'/'A'/'-' } }
  Map<String, Map<String, String>> _attendance = {};

  final _subjectCtrl = TextEditingController();

  static const _depts = [
    'Computer Science','Zoology','Mathematics',
    'English','Urdu','Physics','Pol Science',
  ];
  static const _sems   = ['1st','2nd','3rd','4th','5th','6th','7th','8th'];
  static const _shifts = ['Morning','Evening'];

  @override
  void dispose() {
    _subjectCtrl.dispose();
    super.dispose();
  }

  // ── Date range ───────────────────────────────────────────────
  List<String> _dateRange() {
    final now   = DateTime.now();
    final days  = _period == _Period.week ? 7 : 30;
    final dates = <String>[];
    for (int i = days - 1; i >= 0; i--) {
      dates.add(DateFormat('yyyy-MM-dd')
          .format(now.subtract(Duration(days: i))));
    }
    return dates;
  }

  String get _classPath {
    final dk = _dept.trim().replaceAll(' ', '_').toUpperCase();
    final sn = _sem.replaceAll(RegExp(r'[^0-9]'), '');
    final sk = _shift.trim().toUpperCase();
    return '${dk}_S${sn}_$sk';
  }

  String get _subjectKey =>
      _subject.trim().replaceAll(' ', '_').toUpperCase();

  // ── Fetch ────────────────────────────────────────────────────
  Future<void> _fetch() async {
    if (_subject.trim().isEmpty) {
      setState(() => _error = 'Please enter a subject name');
      return;
    }
    setState(() { _loading = true; _error = ''; _fetched = false; });

    try {
      // 1. Fetch all students of this class from Firestore
      final snap = await _fs
          .collection('Users')
          .where('role',     isEqualTo: 'student')
          .where('dept',     isEqualTo: _dept)
          .where('semester', isEqualTo: _sem)
          .where('shift',    isEqualTo: _shift)
          .get();

      _students = snap.docs.map((d) => {
        'uid'  : d.id,
        'name' : d.data()['name']?.toString()  ?? '',
        'regNo': d.data()['regNo']?.toString() ?? '',
      }).toList();

      // Sort by regNo
      _students.sort((a, b) =>
          a['regNo'].toString().compareTo(b['regNo'].toString()));

      // 2. Get date range
      _dates = _dateRange();

      // 3. Fetch all sessions for this class
      // Sessions stored as SESSION_ID (SUBJECT_TIMESTAMP) keys
      // Filter sessions matching the selected subject
      final classSnap = await _db
          .ref('AttendanceRecords/$_classPath')
          .get();

      final Map<String, Map<String, String>> result = {};
      for (final uid in _students.map((s) => s['uid'] as String)) {
        result[uid] = {};
        for (final date in _dates) {
          result[uid]![date] = '-';
        }
      }

      if (classSnap.exists && classSnap.value != null) {
        final classData = Map<String, dynamic>.from(classSnap.value as Map);

        classData.forEach((sessionId, sessionData) {
          if (sessionData is! Map) return;

          // Extract subject from SESSION_ID — remove trailing _TIMESTAMP
          // AI_1748234567890 → AI
          final extractedSubject = sessionId
              .replaceAll(RegExp(r'_\d{13}$'), '')
              .replaceAll('_', ' ');

          // Check if this session matches selected subject
          final sessionSubjKey = sessionId.replaceAll(RegExp(r'_\d{13}$'), '');
          if (sessionSubjKey != _subjectKey) return;

          // Process dates in this session
          final dateMap = Map<String, dynamic>.from(sessionData);
          dateMap.forEach((date, dateData) {
            if (!_dates.contains(date)) return;
            if (dateData is! Map) return;
            final dayMap = Map<String, dynamic>.from(dateData);
            dayMap.forEach((uid, record) {
              if (!result.containsKey(uid)) return;
              final status = (record is Map
                  ? record['status']?.toString()
                  : record?.toString()) ?? 'Present';
              // If multiple sessions same day — Present overrides Absent
              final mark = status == 'Present' ? 'P' : 'A';
              if (result[uid]![date] != 'P') {
                result[uid]![date] = mark;
              }
            });
          });
        });
      }

      // 4. Check which dates had a session for this class
      // Dates where ANY student has P or A = session existed
      // Dates where all are '-' = no session (don't mark absent)
      final sessionDates = <String>{};
      for (final date in _dates) {
        for (final uid in result.keys) {
          if (result[uid]![date] != '-') {
            sessionDates.add(date);
            break;
          }
        }
      }

      // Mark absent for session dates where student has '-'
      for (final uid in result.keys) {
        for (final date in sessionDates) {
          if (result[uid]![date] == '-') {
            result[uid]![date] = 'A';
          }
        }
      }

      setState(() {
        _attendance = result;
        _loading    = false;
        _fetched    = true;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── Stats per student ────────────────────────────────────────
  Map<String, dynamic> _studentStats(String uid) {
    final records = _attendance[uid] ?? {};
    final sessionDates = records.values.where((v) => v != '-').length;
    final present      = records.values.where((v) => v == 'P').length;
    final absent       = records.values.where((v) => v == 'A').length;
    final pct = sessionDates == 0
        ? 0.0 : present / sessionDates * 100;
    return {
      'present': present,
      'absent' : absent,
      'total'  : sessionDates,
      'pct'    : pct,
    };
  }

  // ── PDF export ───────────────────────────────────────────────
  Future<void> _exportPdf() async {
    final pdf = pw.Document();
    final now = DateFormat('dd MMM yyyy').format(DateTime.now());

    // Visible dates (only session dates)
    final sessionDates = _dates.where((d) {
      for (final uid in _attendance.keys) {
        if (_attendance[uid]![d] != '-') return true;
      }
      return false;
    }).toList();

    // Short date labels
    String shortDate(String d) {
      try { return DateFormat('dd/MM').format(DateTime.parse(d)); }
      catch (_) { return d; }
    }

    // Calculate page width needed:
    // name(80) + regNo(55) + dates(18 each) + P+A+%(30 each) + margins
    final dateCols   = sessionDates.length;
    final minWidth   = 80 + 55 + (dateCols * 18) + 90 + 48.0;
    final pageWidth  = minWidth < 595 ? 595.0  // at least A4 portrait width
                     : minWidth > 1200 ? 1200.0 // cap at 1200
                     : minWidth;
    final pageFormat = PdfPageFormat(pageWidth, 595, // 595 = A4 height
        marginAll: 20);

    pdf.addPage(pw.MultiPage(
      pageFormat: pageFormat,
      margin: const pw.EdgeInsets.all(20),
      build: (ctx) => [
        // Header
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('8B0A1A'),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Expanded(child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Campus Pulse — Attendance Sheet',
                      style: pw.TextStyle(color: PdfColors.white,
                          fontSize: 14, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Dept: $_dept  |  Sem: $_sem  |  Shift: $_shift  |  Subject: $_subject',
                    style: const pw.TextStyle(color: PdfColors.white, fontSize: 9)),
                ],
              )),
              pw.Text('Generated: $now',
                  style: const pw.TextStyle(
                      color: PdfColors.white, fontSize: 9)),
            ],
          ),
        ),
        pw.SizedBox(height: 12),

        // Table — widths sized to always fit on one page width
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          columnWidths: {
            0: const pw.FixedColumnWidth(24),   // #
            1: const pw.FixedColumnWidth(80),   // Name
            2: const pw.FixedColumnWidth(55),   // RegNo
            ...{for (int i = 0; i < sessionDates.length; i++)
              i + 3: const pw.FixedColumnWidth(18)}, // date cols
            sessionDates.length + 3: const pw.FixedColumnWidth(22), // P
            sessionDates.length + 4: const pw.FixedColumnWidth(22), // A
            sessionDates.length + 5: const pw.FixedColumnWidth(28), // %
          },
          children: [
            // Header row
            pw.TableRow(
              decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('8B0A1A')),
              children: [
                '#', 'Name', 'Reg No',
                ...sessionDates.map(shortDate),
                'P', 'A', '%',
              ].map((h) => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 2, vertical: 5),
                child: pw.Text(h,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 7)),
              )).toList(),
            ),

            // Student rows
            ..._students.asMap().entries.map((e) {
              final i    = e.key;
              final s    = e.value;
              final uid  = s['uid'] as String;
              final st   = _studentStats(uid);
              final pct  = (st['pct'] as double).toStringAsFixed(0);
              final pctColor = st['pct'] >= 75
                  ? PdfColors.green700
                  : st['pct'] >= 50
                      ? PdfColors.orange700
                      : PdfColors.red700;

              return pw.TableRow(
                decoration: pw.BoxDecoration(
                    color: i.isEven ? PdfColors.white : PdfColors.grey50),
                children: [
                  _pdfCell((i + 1).toString()),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 2, vertical: 3),
                    child: pw.Text(s['name'].toString(),
                        style: const pw.TextStyle(fontSize: 7),
                        overflow: pw.TextOverflow.clip,
                        maxLines: 2)),
                  _pdfCell(s['regNo'].toString()),
                  ...sessionDates.map((date) {
                    final val = _attendance[uid]?[date] ?? '-';
                    final c   = val == 'P'
                        ? PdfColors.green700
                        : val == 'A'
                            ? PdfColors.red700
                            : PdfColors.grey500;
                    return pw.Padding(
                      padding: const pw.EdgeInsets.all(2),
                      child: pw.Text(val,
                        textAlign: pw.TextAlign.center,
                        style: pw.TextStyle(
                            fontSize: 7,
                            fontWeight: pw.FontWeight.bold,
                            color: c)),
                    );
                  }),
                  _pdfCell(st['present'].toString(),
                      color: PdfColors.green700),
                  _pdfCell(st['absent'].toString(),
                      color: PdfColors.red700),
                  _pdfCell('$pct%', color: pctColor),
                ],
              );
            }),
          ],
        ),
      ],
    ));

    await Printing.layoutPdf(onLayout: (_) async => pdf.save());
  }

  pw.Widget _pdfCell(String text, {PdfColor? color}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 3),
    child: pw.Text(text,
      textAlign: pw.TextAlign.center,
      style: pw.TextStyle(
          fontSize: 7,
          color: color ?? PdfColors.black)),
  );

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        title: const Text('Class Attendance',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_fetched) ...[
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_rounded),
              tooltip: 'Download PDF',
              onPressed: _exportPdf,
            ),
          ],
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _fetched ? _fetch : null,
          ),
        ],
      ),
      body: Column(children: [
        _filterPanel(),
        if (_loading)
          const Expanded(child: Center(
              child: CircularProgressIndicator(color: kPrimary)))
        else if (_error.isNotEmpty)
          Expanded(child: Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center),
          )))
        else if (!_fetched)
          Expanded(child: Center(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.table_chart_rounded,
                  size: 64, color: Colors.grey[300]),
              const SizedBox(height: 16),
              Text('Select filters and tap Fetch',
                  style: TextStyle(color: Colors.grey[500], fontSize: 15)),
            ],
          )))
        else
          Expanded(child: _attendanceTable()),
      ]),
    );
  }

  // ── Filter panel ─────────────────────────────────────────────
  Widget _filterPanel() => Container(
    color: Colors.white,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
    child: Column(children: [
      // Row 1: Dept + Sem
      Row(children: [
        Expanded(child: _dropdown('Department', _depts, _dept,
            (v) => setState(() => _dept = v!))),
        const SizedBox(width: 10),
        Expanded(child: _dropdown('Semester', _sems, _sem,
            (v) => setState(() => _sem = v!))),
      ]),
      const SizedBox(height: 10),
      // Row 2: Shift + Subject
      Row(children: [
        Expanded(child: _dropdown('Shift', _shifts, _shift,
            (v) => setState(() => _shift = v!))),
        const SizedBox(width: 10),
        Expanded(child: TextField(
          controller: _subjectCtrl,
          decoration: _inputDec('Subject Name'),
          onChanged: (v) => _subject = v,
        )),
      ]),
      const SizedBox(height: 10),
      // Row 3: Period + Fetch button
      Row(children: [
        Expanded(child: Row(children: [
          _periodBtn('Week',  _Period.week),
          const SizedBox(width: 8),
          _periodBtn('Month', _Period.month),
        ])),
        const SizedBox(width: 10),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: kPrimary,
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _fetch,
          icon: const Icon(Icons.search_rounded,
              color: Colors.white, size: 18),
          label: const Text('Fetch',
              style: TextStyle(color: Colors.white,
                  fontWeight: FontWeight.bold)),
        ),
      ]),
    ]),
  );

  Widget _periodBtn(String label, _Period p) {
    final selected = _period == p;
    return GestureDetector(
      onTap: () => setState(() => _period = p),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? kPrimary : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? kPrimary : Colors.grey.shade300),
        ),
        child: Text(label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            color: selected ? Colors.white : Colors.grey[700],
          ),
        ),
      ),
    );
  }

  Widget _dropdown(String label, List<String> items, String val,
      Function(String?) onChanged) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.bold, color: kPrimary)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: kBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: val,
              isExpanded: true,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
              items: items.map((s) => DropdownMenuItem(
                  value: s, child: Text(s))).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ]);

  InputDecoration _inputDec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: Colors.grey[400]),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(
        horizontal: 10, vertical: 10),
    filled: true,
    fillColor: kBg,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: Colors.grey.shade300),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: Colors.grey.shade300),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: kPrimary, width: 1.5),
    ),
  );

  // ── Attendance table ─────────────────────────────────────────
  Widget _attendanceTable() {
    // Only show dates that had a session
    final sessionDates = _dates.where((d) {
      for (final uid in _attendance.keys) {
        if (_attendance[uid]![d] != '-') return true;
      }
      return false;
    }).toList();

    if (_students.isEmpty) {
      return Center(child: Text(
        'No students found for this class.',
        style: TextStyle(color: Colors.grey[500])));
    }

    return Column(children: [
      // Stats bar
      _statsBar(sessionDates),
      // Scrollable table
      Expanded(child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildTable(sessionDates),
        ),
      )),
    ]);
  }

  Widget _statsBar(List<String> sessionDates) {
    int totalPresent = 0, totalRecords = 0;
    for (final uid in _attendance.keys) {
      for (final d in sessionDates) {
        final v = _attendance[uid]![d];
        if (v == 'P' || v == 'A') {
          totalRecords++;
          if (v == 'P') totalPresent++;
        }
      }
    }
    final overallPct = totalRecords == 0
        ? 0.0 : totalPresent / totalRecords * 100;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kGold, width: 1.2),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statPill('Students',  _students.length.toString(),   Colors.blue),
          _statPill('Sessions',  sessionDates.length.toString(),Colors.purple),
          _statPill('Overall',   '${overallPct.toStringAsFixed(0)}%',
              overallPct >= 75 ? Colors.green : Colors.orange),
        ],
      ),
    );
  }

  Widget _statPill(String label, String val, Color color) => Column(
    children: [
      Text(val, style: TextStyle(
          fontWeight: FontWeight.bold, fontSize: 18, color: color)),
      Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
    ],
  );

  Widget _buildTable(List<String> sessionDates) {
    // Short date header
    String shortDate(String d) {
      try {
        final dt = DateTime.parse(d);
        return DateFormat('dd\nMMM').format(dt);
      } catch (_) { return d; }
    }

    const double rowH    = 46;
    const double nameW   = 140;
    const double regW    = 80;
    const double dateW   = 38;
    const double statW   = 36;

    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(color: Colors.grey.shade200, width: 0.8),
      columnWidths: {
        0: const FixedColumnWidth(36),    // #
        1: const FixedColumnWidth(nameW), // name
        2: const FixedColumnWidth(regW),  // regNo
        ...{for (int i = 0; i < sessionDates.length; i++)
          i + 3: const FixedColumnWidth(dateW)},
        sessionDates.length + 3: const FixedColumnWidth(statW), // P
        sessionDates.length + 4: const FixedColumnWidth(statW), // A
        sessionDates.length + 5: const FixedColumnWidth(44),    // %
      },
      children: [
        // Header
        TableRow(
          decoration: const BoxDecoration(color: kPrimary),
          children: [
            _th('#'),
            _th('Name'),
            _th('Reg No'),
            ...sessionDates.map((d) => _th(shortDate(d))),
            _th('P'),
            _th('A'),
            _th('%'),
          ],
        ),
        // Student rows
        ..._students.asMap().entries.map((e) {
          final i   = e.key;
          final s   = e.value;
          final uid = s['uid'] as String;
          final st  = _studentStats(uid);
          final pct = st['pct'] as double;
          final pctColor = pct >= 75
              ? Colors.green
              : pct >= 50 ? Colors.orange : Colors.red;

          return TableRow(
            decoration: BoxDecoration(
              color: i.isEven
                  ? Colors.white
                  : const Color(0xFFFDF2F3),
            ),
            children: [
              // Index
              _td((i + 1).toString(),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              // Name
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 4),
                child: Text(s['name'].toString(),
                    style: const TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w600, color: kPrimary),
                    overflow: TextOverflow.ellipsis),
              ),
              // RegNo
              _td(s['regNo'].toString(),
                  style: TextStyle(fontSize: 11, color: Colors.grey[700])),
              // Date cells P/A/-
              ...sessionDates.map((date) {
                final val = _attendance[uid]?[date] ?? '-';
                return _attendanceCell(val);
              }),
              // Present
              _td(st['present'].toString(),
                  style: const TextStyle(fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.green)),
              // Absent
              _td(st['absent'].toString(),
                  style: const TextStyle(fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.red)),
              // Percentage
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.all(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: pctColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('${pct.toStringAsFixed(0)}%',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: pctColor)),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _th(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    alignment: Alignment.center,
    child: Text(text,
      textAlign: TextAlign.center,
      style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 11)),
  );

  Widget _td(String text, {TextStyle? style}) => Container(
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    child: Text(text,
      textAlign: TextAlign.center,
      style: style ?? const TextStyle(fontSize: 11)),
  );

  Widget _attendanceCell(String val) {
    Color bg, textColor;
    if (val == 'P') {
      bg = Colors.green.shade50; textColor = Colors.green.shade700;
    } else if (val == 'A') {
      bg = Colors.red.shade50;   textColor = Colors.red.shade700;
    } else {
      bg = Colors.grey.shade50;  textColor = Colors.grey.shade400;
    }
    return Container(
      alignment: Alignment.center,
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(val,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: textColor)),
    );
  }
}