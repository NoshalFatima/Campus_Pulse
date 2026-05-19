import 'package:flutter/material.dart';
import '../models/announcement_model.dart';

class AnnouncementCard extends StatelessWidget {
  final Announcement data;
  const AnnouncementCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFFBC02D), width: 1.5)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(data.title, style: const TextStyle(color: Color(0xFF8B0A1A), fontSize: 17, fontWeight: FontWeight.bold))),
            Container(padding: const EdgeInsets.all(4), color: const Color(0xFFFDF2F3), child: Text(data.date, style: const TextStyle(fontSize: 11, color: Color(0xFF8B0A1A)))),
          ]),
          const SizedBox(height: 8),
          Text(data.desc, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          Row(children: [
            Chip(label: Text(data.category, style: const TextStyle(fontSize: 10)), backgroundColor: Colors.amber[50]),
            const Spacer(),
            const Text("Read More →", style: TextStyle(color: Color(0xFF8B0A1A), fontWeight: FontWeight.bold)),
          ]),
        ]),
      ),
    );
  }
}