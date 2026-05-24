// lib/Student/student_view_attendance.dart
//
// Features:
//  - Day / Week / Month filter
//  - Subject filter chips
//  - Bar chart — present percentage per subject
//  - Attendance report card with stats
//  - Save as PDF (using pdf + printing packages)

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

// ─────────────────────────────────────────────────────────────
enum _TimeFilter { day, week, month, all }
// ─────────────────────────────────────────────────────────────

class StudentViewAttendance extends StatefulWidget {
  const StudentViewAttendance({super.key});
  @override
  State<StudentViewAttendance> createState() => _StudentViewAttendanceState();
}

class _StudentViewAttendanceState extends State<StudentViewAttendance>
    with SingleTickerProviderStateMixin {

  final _db   = rtdb.FirebaseDatabase.instance;
  final _fs   = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  bool   _loading = true;
  String _error   = '';

  // Student info
  String _name      = '';
  String _regNo     = '';
  String _dept      = '';
  String _sem       = '';
  String _shift     = '';
  String _classPath = '';

  // All records: { subjectKey: [ {date,status,time,subject} ] }
  Map<String, List<Map<String, dynamic>>> _bySubject = {};

  // Filters
  _TimeFilter _timeFilter    = _TimeFilter.month;
  String      _subjectFilter = 'All';

  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── Load data ────────────────────────────────────────────────
  Future<void> _loadData() async {
    setState(() { _loading = true; _error = ''; });
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) throw Exception('Not logged in');

      final doc = await _fs.collection('Users').doc(uid).get();
      if (!doc.exists) throw Exception('Profile not found');

      final d   = doc.data()!;
      _name     = d['name']?.toString()     ?? '';
      _regNo    = d['regNo']?.toString()    ?? '';
      _dept     = d['dept']?.toString()     ?? '';
      _sem      = d['semester']?.toString() ?? d['sem']?.toString() ?? '';
      _shift    = d['shift']?.toString()    ?? '';

      final deptKey  = _dept.trim().replaceAll(' ', '_').toUpperCase();
      final semNum   = _sem.replaceAll(RegExp(r'[^0-9]'), '');
      final shiftKey = _shift.trim().toUpperCase();
      _classPath     = '${deptKey}_S${semNum}_$shiftKey';

      final snap = await _db.ref('AttendanceRecords/$_classPath').get();

      final Map<String, List<Map<String, dynamic>>> grouped = {};

      if (snap.exists && snap.value != null) {
        final classData = Map<String, dynamic>.from(snap.value as Map);

        classData.forEach((sessionId, sessionData) {
          if (sessionData is! Map) return;

          // SESSION_ID = SUBJECT_TIMESTAMP e.g. AI_1748234567890
          // Extract subject key by removing trailing timestamp
          final subjectKey = sessionId.replaceAll(
              RegExp(r'_\d{13}' r'$'), '');
          final subjectDisplay = subjectKey.replaceAll('_', ' ');

          final dateMap = Map<String, dynamic>.from(sessionData);

          dateMap.forEach((date, dateData) {
            if (dateData is! Map) return;
            final dayMap = Map<String, dynamic>.from(dateData);

            if (dayMap.containsKey(uid)) {
              final record = Map<String, dynamic>.from(dayMap[uid] as Map);
              final subjName = record['subject']?.toString().isNotEmpty == true
                  ? record['subject'].toString()
                  : subjectDisplay;

              grouped.putIfAbsent(subjectKey, () => []);
              grouped[subjectKey]!.add({
                'date'      : date,
                'status'    : record['status']?.toString() ?? 'Present',
                'subject'   : subjName,
                'subjectKey': subjectKey,
                'sessionId' : sessionId,
                'time'      : record['timestamp'] != null
                    ? DateFormat('hh:mm a').format(
                        DateTime.fromMillisecondsSinceEpoch(
                            (record['timestamp'] as num).toInt()))
                    : '--',
                'timestamp' : record['timestamp'] ?? 0,
              });
            }
          });
        });
      }

      grouped.forEach((key, list) {
        list.sort((a, b) => (b['timestamp'] as num)
            .compareTo(a['timestamp'] as num));
      });

      setState(() { _bySubject = grouped; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── Filter logic ─────────────────────────────────────────────
  List<Map<String, dynamic>> get _allRecords =>
      _bySubject.values.expand((l) => l).toList()
        ..sort((a, b) => (b['timestamp'] as num)
            .compareTo(a['timestamp'] as num));

  List<Map<String, dynamic>> _applyTimeFilter(
      List<Map<String, dynamic>> records) {
    final now = DateTime.now();
    return records.where((r) {
      try {
        final d = DateTime.parse(r['date']);
        switch (_timeFilter) {
          case _TimeFilter.day:
            return d.year == now.year &&
                   d.month == now.month &&
                   d.day == now.day;
          case _TimeFilter.week:
            final diff = now.difference(d).inDays;
            return diff >= 0 && diff < 7;
          case _TimeFilter.month:
            return d.year == now.year && d.month == now.month;
          case _TimeFilter.all:
            return true;
        }
      } catch (_) { return true; }
    }).toList();
  }

  List<Map<String, dynamic>> get _filteredRecords {
    var records = _subjectFilter == 'All'
        ? _allRecords
        : (_bySubject[_subjectFilter
               .replaceAll(' ', '_').toUpperCase()] ?? []);
    return _applyTimeFilter(records);
  }

  List<String> get _subjects =>
      ['All', ..._bySubject.keys.map((k) => k.replaceAll('_', ' '))];

  int _presentCount(List<Map<String, dynamic>> records) =>
      records.where((r) => r['status'] == 'Present').length;

  double _percentage(List<Map<String, dynamic>> records) {
    if (records.isEmpty) return 0;
    return _presentCount(records) / records.length * 100;
  }

  // ── PDF export ───────────────────────────────────────────────
  Future<void> _exportPdf() async {
    final pdf  = pw.Document();
    final recs = _filteredRecords;
    final pct  = _percentage(recs).toStringAsFixed(0);
    final now  = DateFormat('dd MMM yyyy').format(DateTime.now());
    final filterLabel = _timeFilterLabel(_timeFilter);

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (ctx) => [
        // Header
        pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('8B0A1A'),
            borderRadius: pw.BorderRadius.circular(8),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Campus Pulse — Attendance Report',
                  style: pw.TextStyle(
                      color: PdfColors.white, fontSize: 18,
                      fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              pw.Text('Generated: $now',
                  style: const pw.TextStyle(color: PdfColors.white, fontSize: 11)),
            ],
          ),
        ),
        pw.SizedBox(height: 16),

        // Student info
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColor.fromHex('FBC02D')),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Student: $_name',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13)),
              pw.Text('Reg No: $_regNo', style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Class: $_dept | Sem $_sem | $_shift',
                  style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Filter: $filterLabel | Subject: $_subjectFilter',
                  style: const pw.TextStyle(fontSize: 12)),
            ],
          ),
        ),
        pw.SizedBox(height: 12),

        // Stats
        pw.Row(children: [
          _pdfStat('Total Classes', recs.length.toString()),
          pw.SizedBox(width: 12),
          _pdfStat('Present', _presentCount(recs).toString()),
          pw.SizedBox(width: 12),
          _pdfStat('Absent',
              (recs.length - _presentCount(recs)).toString()),
          pw.SizedBox(width: 12),
          _pdfStat('Percentage', '$pct%'),
        ]),
        pw.SizedBox(height: 16),

        // Table header
        pw.Text('Attendance Records',
            style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 13,
                color: PdfColor.fromHex('8B0A1A'))),
        pw.SizedBox(height: 8),

        // Table
        pw.Table(
          border: pw.TableBorder.all(
              color: PdfColors.grey300, width: 0.5),
          columnWidths: {
            0: const pw.FlexColumnWidth(2.5),
            1: const pw.FlexColumnWidth(1.5),
            2: const pw.FlexColumnWidth(1.2),
            3: const pw.FlexColumnWidth(1.2),
          },
          children: [
            // Header row
            pw.TableRow(
              decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('8B0A1A')),
              children: ['Subject', 'Date', 'Time', 'Status']
                  .map((h) => pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(h,
                            style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11)),
                      ))
                  .toList(),
            ),
            // Data rows
            ...recs.asMap().entries.map((e) {
              final i = e.key;
              final r = e.value;
              String displayDate = r['date'];
              try {
                displayDate = DateFormat('dd MMM yyyy')
                    .format(DateTime.parse(r['date']));
              } catch (_) {}
              return pw.TableRow(
                decoration: pw.BoxDecoration(
                    color: i.isEven ? PdfColors.white : PdfColors.grey50),
                children: [
                  r['subject'].toString(),
                  displayDate,
                  r['time'].toString(),
                  r['status'].toString(),
                ].map((cell) => pw.Padding(
                      padding: const pw.EdgeInsets.all(7),
                      child: pw.Text(cell,
                          style: pw.TextStyle(
                              fontSize: 10,
                              color: cell == 'Present'
                                  ? PdfColors.green700
                                  : cell == 'Absent'
                                      ? PdfColors.red700
                                      : PdfColors.black)),
                    )).toList(),
              );
            }),
          ],
        ),
      ],
    ));

    await Printing.layoutPdf(
      onLayout: (fmt) async => pdf.save(),
    );
  }

  pw.Widget _pdfStat(String label, String value) => pw.Expanded(
    child: pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('FDF2F3'),
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(children: [
        pw.Text(value, style: pw.TextStyle(
            fontWeight: pw.FontWeight.bold,
            fontSize: 16,
            color: PdfColor.fromHex('8B0A1A'))),
        pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
      ]),
    ),
  );

  String _timeFilterLabel(_TimeFilter f) {
    switch (f) {
      case _TimeFilter.day:   return 'Today';
      case _TimeFilter.week:  return 'This Week';
      case _TimeFilter.month: return 'This Month';
      case _TimeFilter.all:   return 'All Time';
    }
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        title: const Text('My Attendance',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_rounded),
            tooltip: 'Save as PDF',
            onPressed: _filteredRecords.isEmpty ? null : _exportPdf,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadData,
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: kGold,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(icon: Icon(Icons.list_alt_rounded), text: 'Records'),
            Tab(icon: Icon(Icons.bar_chart_rounded), text: 'Analytics'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kPrimary))
          : _error.isNotEmpty
              ? _errorWidget()
              : Column(children: [
                  _studentCard(),
                  _timeFilterRow(),
                  _subjectChips(),
                  _summaryRow(),
                  Expanded(child: TabBarView(
                    controller: _tabCtrl,
                    children: [
                      _recordsTab(),
                      _analyticsTab(),
                    ],
                  )),
                ]),
    );
  }

  // ── Student card ─────────────────────────────────────────────
  Widget _studentCard() => Container(
    margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: kGold, width: 1.5),
      boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 8, offset: const Offset(0, 3))],
    ),
    child: Row(children: [
      Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: kPrimary.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.person_rounded, color: kPrimary, size: 26),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_name, style: const TextStyle(
              fontWeight: FontWeight.bold, fontSize: 15, color: kPrimary)),
          Text('Reg: $_regNo',
              style: TextStyle(fontSize: 12, color: Colors.grey[700])),
          Text('$_dept  •  Sem $_sem  •  $_shift',
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ],
      )),
      // Overall percentage badge
      _percentBadge(_percentage(_filteredRecords)),
    ]),
  );

  Widget _percentBadge(double pct) {
    final color = pct >= 75
        ? Colors.green
        : pct >= 50
            ? Colors.orange
            : Colors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(children: [
        Text('${pct.toStringAsFixed(0)}%',
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 18, color: color)),
        Text('Attendance',
            style: TextStyle(fontSize: 9, color: color)),
      ]),
    );
  }

  // ── Time filter row ──────────────────────────────────────────
  Widget _timeFilterRow() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
    child: Row(children: _TimeFilter.values.map((f) {
      final selected = f == _timeFilter;
      return Expanded(child: GestureDetector(
        onTap: () => setState(() => _timeFilter = f),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? kPrimary : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? kPrimary : Colors.grey.shade300),
            boxShadow: selected ? [BoxShadow(
                color: kPrimary.withOpacity(0.25), blurRadius: 6)] : null,
          ),
          child: Text(_timeFilterLabel(f),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: selected ? Colors.white : Colors.grey[600],
            ),
          ),
        ),
      ));
    }).toList(),
  ));

  // ── Subject chips ────────────────────────────────────────────
  Widget _subjectChips() => SizedBox(
    height: 42,
    child: ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      itemCount: _subjects.length,
      itemBuilder: (_, i) {
        final s        = _subjects[i];
        final selected = s == _subjectFilter;
        return GestureDetector(
          onTap: () => setState(() => _subjectFilter = s),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? kGold : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: selected ? kGold : Colors.grey.shade300),
            ),
            child: Text(s,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: selected ? Colors.brown[900] : Colors.grey[700],
              ),
            ),
          ),
        );
      },
    ),
  );

  // ── Summary row ──────────────────────────────────────────────
  Widget _summaryRow() {
    final recs    = _filteredRecords;
    final present = _presentCount(recs);
    final absent  = recs.length - present;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [
        _statChip(recs.length.toString(),  'Classes',
            Icons.calendar_today_rounded, Colors.blue),
        const SizedBox(width: 8),
        _statChip(present.toString(), 'Present',
            Icons.check_circle_rounded, Colors.green),
        const SizedBox(width: 8),
        _statChip(absent.toString(),  'Absent',
            Icons.cancel_rounded, Colors.red),
      ]),
    );
  }

  Widget _statChip(String val, String label, IconData icon, Color color) =>
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(val, style: TextStyle(
              fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          Text(label, style: TextStyle(fontSize: 10, color: color)),
        ]),
      ));

  // ── Records tab ──────────────────────────────────────────────
  Widget _recordsTab() {
    final recs = _filteredRecords;
    if (recs.isEmpty) return _emptyWidget();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      itemCount: recs.length,
      itemBuilder: (_, i) => _recordCard(recs[i]),
    );
  }

  Widget _recordCard(Map<String, dynamic> r) {
    final isPresent = r['status'] == 'Present';
    String displayDate = r['date'];
    try {
      displayDate = DateFormat('EEE, dd MMM yyyy')
          .format(DateTime.parse(r['date']));
    } catch (_) {}

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPresent ? Colors.green.shade200 : Colors.red.shade200,
          width: 1.2,
        ),
        boxShadow: [BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            color: isPresent ? Colors.green.shade50 : Colors.red.shade50,
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPresent ? Icons.check_rounded : Icons.close_rounded,
            color: isPresent ? Colors.green : Colors.red, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r['subject']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.bold,
                    fontSize: 14, color: kPrimary)),
            const SizedBox(height: 2),
            Text(displayDate,
                style: TextStyle(fontSize: 12, color: Colors.grey[700])),
            Text('Time: ${r['time']}',
                style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          ],
        )),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isPresent
                ? Colors.green.shade100 : Colors.red.shade100,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            isPresent ? 'Present' : 'Absent',
            style: TextStyle(
              color: isPresent
                  ? Colors.green.shade800 : Colors.red.shade800,
              fontWeight: FontWeight.bold, fontSize: 12,
            ),
          ),
        ),
      ]),
    );
  }

  // ── Analytics tab — bar chart ────────────────────────────────
  Widget _analyticsTab() {
    if (_bySubject.isEmpty) return _emptyWidget();

    // Build per-subject stats for current time filter
    final subjectStats = <String, Map<String, int>>{};
    _bySubject.forEach((key, records) {
      final filtered = _applyTimeFilter(records);
      if (filtered.isEmpty) return;
      subjectStats[key] = {
        'total'  : filtered.length,
        'present': _presentCount(filtered),
      };
    });

    if (subjectStats.isEmpty) return _emptyWidget();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // Chart title
        const Text('Attendance by Subject',
            style: TextStyle(fontWeight: FontWeight.bold,
                fontSize: 15, color: kPrimary)),
        const SizedBox(height: 12),

        // Bar chart (custom painted)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: Column(
            children: subjectStats.entries.map((e) {
              final subj    = e.key.replaceAll('_', ' ');
              final total   = e.value['total']!;
              final present = e.value['present']!;
              final pct     = total == 0 ? 0.0 : present / total;
              final color   = pct >= 0.75
                  ? Colors.green
                  : pct >= 0.50
                      ? Colors.orange
                      : Colors.red;

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(subj,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600,
                                color: kPrimary),
                            overflow: TextOverflow.ellipsis)),
                        Text('$present/$total  (${(pct*100).toStringAsFixed(0)}%)',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold,
                                color: color)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Background track
                    Stack(children: [
                      Container(
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      // Fill bar
                      FractionallySizedBox(
                        widthFactor: pct.clamp(0.0, 1.0),
                        child: Container(
                          height: 14,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(7),
                            boxShadow: [BoxShadow(
                                color: color.withOpacity(0.4),
                                blurRadius: 4)],
                          ),
                        ),
                      ),
                    ]),
                  ],
                ),
              );
            }).toList(),
          ),
        ),

        const SizedBox(height: 16),

        // Legend
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Percentage Guide',
                  style: TextStyle(fontWeight: FontWeight.bold,
                      fontSize: 13, color: kPrimary)),
              const SizedBox(height: 10),
              _legendRow(Colors.green, '75% and above', 'Good standing'),
              const SizedBox(height: 6),
              _legendRow(Colors.orange, '50% - 74%', 'At risk'),
              const SizedBox(height: 6),
              _legendRow(Colors.red, 'Below 50%', 'Critical — may be detained'),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Per subject detail cards
        const Text('Subject Breakdown',
            style: TextStyle(fontWeight: FontWeight.bold,
                fontSize: 15, color: kPrimary)),
        const SizedBox(height: 10),

        ...subjectStats.entries.map((e) {
          final subj    = e.key.replaceAll('_', ' ');
          final total   = e.value['total']!;
          final present = e.value['present']!;
          final absent  = total - present;
          final pct     = total == 0 ? 0.0 : present / total * 100;
          final color   = pct >= 75
              ? Colors.green
              : pct >= 50 ? Colors.orange : Colors.red;

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Row(children: [
              // Circle percentage
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(0.1),
                  border: Border.all(color: color, width: 2),
                ),
                child: Center(child: Text(
                  '${pct.toStringAsFixed(0)}%',
                  style: TextStyle(fontWeight: FontWeight.bold,
                      fontSize: 12, color: color),
                )),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(subj,
                      style: const TextStyle(fontWeight: FontWeight.bold,
                          fontSize: 13, color: kPrimary)),
                  const SizedBox(height: 4),
                  Row(children: [
                    _miniChip('$present Present', Colors.green),
                    const SizedBox(width: 6),
                    _miniChip('$absent Absent', Colors.red),
                    const SizedBox(width: 6),
                    _miniChip('$total Total', Colors.blue),
                  ]),
                ],
              )),
            ]),
          );
        }),
      ],
    );
  }

  Widget _legendRow(Color color, String label, String desc) =>
      Row(children: [
        Container(width: 14, height: 14,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 8),
        Text('$label — ', style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        Text(desc, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ]);

  Widget _miniChip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text,
        style: TextStyle(fontSize: 10, color: color,
            fontWeight: FontWeight.bold)),
  );

  Widget _emptyWidget() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.event_busy_rounded, size: 64, color: Colors.grey[300]),
      const SizedBox(height: 16),
      Text('No records for ${_timeFilterLabel(_timeFilter).toLowerCase()}',
          style: TextStyle(fontSize: 15, color: Colors.grey[500])),
      const SizedBox(height: 6),
      Text('Try changing the time filter above',
          style: TextStyle(fontSize: 12, color: Colors.grey[400])),
    ]),
  );

  Widget _errorWidget() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.error_outline_rounded, size: 56, color: kPrimary),
        const SizedBox(height: 16),
        Text(_error, textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 16),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
          onPressed: _loadData,
          child: const Text('Retry',
              style: TextStyle(color: Colors.white)),
        ),
      ]),
    ),
  );
}