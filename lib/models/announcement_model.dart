// lib/models/announcement_model.dart — NO HIVE GENERATOR NEEDED
// Uses manual adapter instead of annotations

import 'package:hive/hive.dart';

class Announcement {
  final String id;
  final String title;
  final String desc;
  final String sem;
  final String dept;
  final String shift;
  final String date;
  final String type;
  final String category;
  final String teacherName;
  final String teacherId;
  final bool isUrgent;
  final String target;
  bool isRead;

  Announcement({
    required this.id,
    required this.title,
    required this.desc,
    required this.sem,
    required this.dept,
    required this.shift,
    required this.date,
    required this.type,
    required this.category,
    required this.teacherName,
    required this.teacherId,
    this.isUrgent = false,
    this.target = '',
    this.isRead = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'desc': desc,
        'sem': sem,
        'dept': dept,
        'shift': shift,
        'date': date,
        'type': type,
        'category': category,
        'teacherName': teacherName,
        'teacherId': teacherId,
        'isUrgent': isUrgent,
        'target': target,
      };

  factory Announcement.fromMap(Map<String, dynamic> map) {
    return Announcement(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      desc: map['desc']?.toString() ?? '',
      sem: (map['semester'] ?? map['sem'] ?? '').toString(),
      dept: map['dept']?.toString() ?? '',
      shift: map['shift']?.toString() ?? '',
      date: map['date']?.toString() ?? '',
      type: map['type']?.toString() ?? '',
      category: map['category']?.toString() ?? '',
      teacherName: map['teacherName']?.toString() ?? '',
      teacherId: map['teacherId']?.toString() ?? '',
      isUrgent: map['isUrgent'] == true,
      target: map['target']?.toString() ?? '',
    );
  }
}

// ── Manual Hive Adapter (no build_runner needed) ───────────────────────────
class AnnouncementAdapter extends TypeAdapter<Announcement> {
  @override
  final int typeId = 0;

  @override
  Announcement read(BinaryReader reader) {
    return Announcement(
      id:          reader.readString(),
      title:       reader.readString(),
      desc:        reader.readString(),
      sem:         reader.readString(),
      dept:        reader.readString(),
      shift:       reader.readString(),
      date:        reader.readString(),
      type:        reader.readString(),
      category:    reader.readString(),
      teacherName: reader.readString(),
      teacherId:   reader.readString(),
      isUrgent:    reader.readBool(),
      target:      reader.readString(),
    );
  }

  @override
  void write(BinaryWriter writer, Announcement obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.title);
    writer.writeString(obj.desc);
    writer.writeString(obj.sem);
    writer.writeString(obj.dept);
    writer.writeString(obj.shift);
    writer.writeString(obj.date);
    writer.writeString(obj.type);
    writer.writeString(obj.category);
    writer.writeString(obj.teacherName);
    writer.writeString(obj.teacherId);
    writer.writeBool(obj.isUrgent);
    writer.writeString(obj.target);
  }
}