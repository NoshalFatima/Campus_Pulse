// ✅ lib/users_list_fragment.dart — HIVE CACHE VERSION
//
// HIVE CACHING:
// ✅ Box 1: 'users_cache'           — UserProfile list (Firestore)
// ✅ Box 2: 'chat_meta_{uid}'       — last message / time / unread per partner (RTDB)
// ✅ Box 3: 'groups_cache_{uid}'    — Groups list (Firestore)
// ✅ All boxes open instantly → data shows before any network call
// ✅ Streams update UI + save to Hive in background
//
// OTHER FEATURES:
// ✅ CachedNetworkImage — profile pics & group DPs cached
// ✅ UserProfile — 'semester' + 'batch' fields (signup se exact match)
// ✅ Create Group dialog — Name / Dept / Semester / Batch filters
// ✅ Group tile onTap → GroupChatScreen
// ✅ All stream subscriptions properly disposed

import 'dart:async';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';
import '../models/chat_models.dart';
import '../chat/chat_screen.dart';
import '../chat/group_chat_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Hive box names
// ─────────────────────────────────────────────────────────────────────────────
const String _kUsersBox  = 'users_cache';
const String _kMetaBox   = 'chat_meta_';   // + currentUserId
const String _kGroupsBox = 'groups_cache_'; // + currentUserId

class UsersListFragment extends StatefulWidget {
  const UsersListFragment({super.key});

  @override
  State<UsersListFragment> createState() => _UsersListFragmentState();
}

class _UsersListFragmentState extends State<UsersListFragment> {
  // ── Auth ──────────────────────────────────────────────────────────────────
  final String currentUserId = FirebaseAuth.instance.currentUser!.uid;

  // ── Tab / Search ──────────────────────────────────────────────────────────
  String selectedTab     = 'student';
  String searchQuery     = '';
  String currentUserRole = 'student';

  // ── Users (Firestore, cached in Hive) ─────────────────────────────────────
  List<UserProfile> _users        = [];   // live from Firestore
  List<UserProfile> _cachedUsers  = [];   // from Hive (shown instantly)

  // ── Groups (Firestore, cached in Hive) ────────────────────────────────────
  List<Map<String, dynamic>> _groups       = [];
  List<Map<String, dynamic>> _cachedGroups = [];

  // ── Chat metadata (RTDB, cached in Hive) ──────────────────────────────────
  final Map<String, int>    _unreadCounts     = {};
  final Map<String, int>    _lastMessageTimes = {};
  final Map<String, String> _lastMessages     = {};

  // ── Tab unread counts ─────────────────────────────────────────────────────
  int _studentUnread = 0;
  int _teacherUnread = 0;
  int _groupUnread   = 0;
  int _totalUnread   = 0;

  // ── User roles map uid→role ───────────────────────────────────────────────
  Map<String, String> _userRoles = {};

  // ── Hive boxes ────────────────────────────────────────────────────────────
  Box<String>? _usersBox;
  Box<String>? _metaBox;
  Box<String>? _groupsBox;

  // ── Stream subscriptions ──────────────────────────────────────────────────
  StreamSubscription? _usersStreamSub;
  StreamSubscription? _groupsStreamSub;
  StreamSubscription? _chatsIndexListener;
  final Map<String, StreamSubscription> _chatListeners    = {};
  final List<StreamSubscription>        _deliveryListeners = [];

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _openHiveBoxes().then((_) {
      // Show cached data instantly, then fetch fresh
      _fetchCurrentUserRole();
      _fetchAllUserRoles().then((_) {
        _listenUsers();
        _listenGroups();
        _listenToChatsIndex();
        _listenForDelivery();
      });
    });
  }

  @override
  void dispose() {
    _usersStreamSub?.cancel();
    _groupsStreamSub?.cancel();
    _chatsIndexListener?.cancel();
    for (final sub in _chatListeners.values) sub.cancel();
    for (final sub in _deliveryListeners) sub.cancel();
    _usersBox?.close();
    _metaBox?.close();
    _groupsBox?.close();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ OPEN ALL HIVE BOXES — then load caches → instant display
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _openHiveBoxes() async {
    if (kIsWeb) return;
    try {
      _usersBox  = await Hive.openBox<String>(_kUsersBox);
      _metaBox   = await Hive.openBox<String>('$_kMetaBox$currentUserId');
      _groupsBox = await Hive.openBox<String>('$_kGroupsBox$currentUserId');
      debugPrint('✅ Hive: users=${_usersBox!.length} '
          'meta=${_metaBox!.length} groups=${_groupsBox!.length}');
      _loadUsersFromHive();
      _loadMetaFromHive();
      _loadGroupsFromHive();
    } catch (e) {
      debugPrint('❌ Hive open: $e');
    }
  }

  // ── Load Users from Hive ──────────────────────────────────────────────────
  void _loadUsersFromHive() {
    if (_usersBox == null) return;
    final List<UserProfile> cached = [];
    for (final entry in _usersBox!.toMap().entries) {
      try {
        final Map<String, dynamic> m =
            Map<String, dynamic>.from(jsonDecode(entry.value) as Map);
        cached.add(UserProfile.fromMap(m, entry.key.toString()));
      } catch (_) {}
    }
    if (mounted && cached.isNotEmpty) {
      setState(() => _cachedUsers = cached);
    }
  }

  Future<void> _saveUsersToHive(List<UserProfile> users) async {
    if (_usersBox == null || kIsWeb) return;
    try {
      final Map<String, String> entries = {};
      for (final u in users) {
        entries[u.uid] = jsonEncode({
          'name': u.name, 'email': u.email, 'profilePic': u.profilePic,
          'dept': u.dept, 'role': u.role,
          'semester': u.semester, 'batch': u.batch,
        });
      }
      await _usersBox!.clear();
      await _usersBox!.putAll(entries);
    } catch (e) {
      debugPrint('❌ Hive saveUsers: $e');
    }
  }

  // ── Load Chat Meta from Hive ───────────────────────────────────────────────
  void _loadMetaFromHive() {
    if (_metaBox == null) return;
    try {
      for (final entry in _metaBox!.toMap().entries) {
        final String partnerId = entry.key.toString();
        final Map<String, dynamic> m =
            Map<String, dynamic>.from(jsonDecode(entry.value) as Map);
        _unreadCounts[partnerId]     = (m['unread'] as num?)?.toInt() ?? 0;
        _lastMessageTimes[partnerId] = (m['lastTime'] as num?)?.toInt() ?? 0;
        _lastMessages[partnerId]     = m['lastMsg']?.toString() ?? '';
      }
      if (mounted) {
        setState(() => _recalcTabUnreads());
      }
    } catch (e) {
      debugPrint('❌ Hive loadMeta: $e');
    }
  }

  Future<void> _saveMetaToHive(
      String partnerId, int unread, int lastTime, String lastMsg) async {
    if (_metaBox == null || kIsWeb) return;
    try {
      await _metaBox!.put(partnerId, jsonEncode({
        'unread':   unread,
        'lastTime': lastTime,
        'lastMsg':  lastMsg,
      }));
    } catch (e) {
      debugPrint('❌ Hive saveMeta: $e');
    }
  }

  // ── Load Groups from Hive ─────────────────────────────────────────────────
  void _loadGroupsFromHive() {
    if (_groupsBox == null) return;
    try {
      final List<Map<String, dynamic>> cached = [];
      for (final jsonStr in _groupsBox!.values) {
        final Map<String, dynamic> m =
            Map<String, dynamic>.from(jsonDecode(jsonStr) as Map);
        cached.add(m);
      }
      // Sort by lastMessageTime desc
      cached.sort((a, b) {
        final int tA = (a['lastMessageTimeMs'] as num?)?.toInt() ?? 0;
        final int tB = (b['lastMessageTimeMs'] as num?)?.toInt() ?? 0;
        return tB.compareTo(tA);
      });
      if (mounted && cached.isNotEmpty) {
        setState(() => _cachedGroups = cached);
      }
    } catch (e) {
      debugPrint('❌ Hive loadGroups: $e');
    }
  }

  Future<void> _saveGroupsToHive(List<Map<String, dynamic>> groups) async {
    if (_groupsBox == null || kIsWeb) return;
    try {
      await _groupsBox!.clear();
      final Map<String, String> entries = {};
      for (final g in groups) {
        final String id = g['_id']?.toString() ?? '';
        if (id.isNotEmpty) entries[id] = jsonEncode(g);
      }
      await _groupsBox!.putAll(entries);
    } catch (e) {
      debugPrint('❌ Hive saveGroups: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FETCH CURRENT USER ROLE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _fetchCurrentUserRole() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('Users').doc(currentUserId).get();
      if (mounted && doc.exists) {
        setState(() {
          currentUserRole =
              (doc.data()?['role'] ?? 'student').toString().toLowerCase();
        });
      }
    } catch (e) {
      debugPrint('❌ fetchCurrentUserRole: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRE-FETCH ALL USER ROLES
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _fetchAllUserRoles() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('Users').get();
      final Map<String, String> roles = {};
      for (final doc in snap.docs) {
        roles[doc.id] =
            (doc.data()['role'] ?? 'student').toString().toLowerCase();
      }
      if (mounted) setState(() => _userRoles = roles);
    } catch (e) {
      debugPrint('❌ fetchAllUserRoles: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ LISTEN USERS (Firestore stream + Hive save)
  // ─────────────────────────────────────────────────────────────────────────
  void _listenUsers() {
    _usersStreamSub = FirebaseFirestore.instance
        .collection('Users')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final List<UserProfile> fresh = snapshot.docs
          .where((doc) => doc.data() != null)
          .map((doc) =>
              UserProfile.fromMap(doc.data() as Map<String, dynamic>, doc.id))
          .toList();

      setState(() {
        _users = fresh;
        // Keep roles fresh
        final Map<String, String> roles = {};
        for (final u in fresh) roles[u.uid] = u.role.toLowerCase();
        _userRoles = roles;
        _recalcTabUnreads();
      });

      _saveUsersToHive(fresh);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ LISTEN GROUPS (Firestore stream + Hive save)
  // ─────────────────────────────────────────────────────────────────────────
  void _listenGroups() {
    _groupsStreamSub = FirebaseFirestore.instance
        .collection('Groups')
        .where('members', arrayContains: currentUserId)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final List<Map<String, dynamic>> fresh = snapshot.docs.map((doc) {
        final data = doc.data();
        final Timestamp? ts = data['lastMessageTime'] as Timestamp?;
        return {
          ...data,
          '_id': doc.id,
          'lastMessageTimeMs': ts?.millisecondsSinceEpoch ?? 0,
        };
      }).toList();

      fresh.sort((a, b) {
        final int tA = (a['lastMessageTimeMs'] as num?)?.toInt() ?? 0;
        final int tB = (b['lastMessageTimeMs'] as num?)?.toInt() ?? 0;
        return tB.compareTo(tA);
      });

      setState(() => _groups = fresh);
      _saveGroupsToHive(fresh);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CHAT INDEX LISTENER → per-chat subscriptions (RTDB)
  // ─────────────────────────────────────────────────────────────────────────
  void _listenToChatsIndex() {
    _chatsIndexListener = FirebaseDatabase.instance
        .ref('Chats')
        .onValue
        .listen((event) {
      if (!mounted || event.snapshot.value == null) return;
      final Map allChats = event.snapshot.value as Map;
      allChats.forEach((chatId, _) {
        final String cId = chatId.toString();
        if (!cId.contains(currentUserId)) return;
        if (_chatListeners.containsKey(cId)) return;

        final List<String> parts = cId.split('_');
        if (parts.length < 2) return;
        final String partnerId =
            parts[0] == currentUserId ? parts[1] : parts[0];

        final sub = FirebaseDatabase.instance
            .ref('Chats')
            .child(cId)
            .onValue
            .listen((chatEvent) {
          if (!mounted) return;
          _processChatSnapshot(partnerId, chatEvent.snapshot);
        });
        _chatListeners[cId] = sub;
      });
    });
  }

  void _processChatSnapshot(String partnerId, DataSnapshot snapshot) {
    int unread = 0, lastTime = 0;
    String lastMsg = '';

    if (snapshot.value != null && snapshot.value is Map) {
      final Map chatData = snapshot.value as Map;
      chatData.forEach((key, value) {
        if (value == null || value is! Map) return;
        try {
          final Map msg = value;
          if (msg['isRead'] == false &&
              msg['senderId']?.toString() != currentUserId &&
              msg['isDeleted'] != true) {
            unread++;
          }
          final int msgTime = (msg['timestamp'] is int)
              ? msg['timestamp'] as int
              : int.tryParse(msg['timestamp']?.toString() ?? '0') ?? 0;
          if (msgTime > lastTime) {
            lastTime = msgTime;
            final String txt = msg['text']?.toString() ?? '';
            if (txt.startsWith('http') && txt.contains('cloudinary.com')) {
              lastMsg = (txt.contains('.pdf') || txt.contains('/raw/upload/'))
                  ? '📄 Document'
                  : '🖼️ Photo';
            } else if (msg['isDeleted'] == true) {
              lastMsg = 'This message was deleted';
            } else {
              lastMsg = txt;
            }
          }
        } catch (_) {}
      });
    }

    if (mounted) {
      setState(() {
        _unreadCounts[partnerId]     = unread;
        _lastMessageTimes[partnerId] = lastTime;
        _lastMessages[partnerId]     = lastMsg;
        _recalcTabUnreads();
      });
      // ✅ Save chat meta to Hive
      _saveMetaToHive(partnerId, unread, lastTime, lastMsg);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DELIVERY LISTENER (RTDB)
  // ─────────────────────────────────────────────────────────────────────────
  void _listenForDelivery() {
    final topSub = FirebaseDatabase.instance
        .ref('Chats')
        .onValue
        .listen((event) {
      if (event.snapshot.value == null) return;
      final Map allChats = event.snapshot.value as Map;
      allChats.forEach((chatId, _) {
        final String cId = chatId.toString();
        if (!cId.contains(currentUserId)) return;
        final chatRef = FirebaseDatabase.instance.ref('Chats').child(cId);
        _deliveryListeners
          ..add(chatRef.onChildAdded
              .listen((e) => _markDelivered(chatRef, e.snapshot)))
          ..add(chatRef.onChildChanged
              .listen((e) => _markDelivered(chatRef, e.snapshot)));
      });
    });
    _deliveryListeners.add(topSub);
  }

  void _markDelivered(DatabaseReference chatRef, DataSnapshot snapshot) {
    try {
      if (snapshot.value == null || snapshot.value is! Map) return;
      final Map msg = snapshot.value as Map;
      if (msg['senderId']?.toString() != currentUserId &&
          msg['isDelivered'] != true &&
          msg['isDeleted'] != true) {
        chatRef.child(snapshot.key!).update({'isDelivered': true});
      }
    } catch (e) {
      debugPrint('❌ markDelivered: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // RECALC TAB UNREADS
  // ─────────────────────────────────────────────────────────────────────────
  void _recalcTabUnreads() {
    int sUnread = 0, tUnread = 0;
    _unreadCounts.forEach((partnerId, count) {
      if (count == 0) return;
      final String role = _userRoles[partnerId] ?? '';
      if (role == 'student') sUnread += count;
      if (role == 'teacher') tUnread += count;
    });
    _studentUnread = sUnread;
    _teacherUnread = tUnread;
    _totalUnread   = sUnread + tUnread + _groupUnread;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // TIME FORMAT
  // ─────────────────────────────────────────────────────────────────────────
  String _formatTime(int timestamp) {
    if (timestamp == 0) return '';
    final dt        = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now       = DateTime.now();
    final today     = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDate   = DateTime(dt.year, dt.month, dt.day);
    if (msgDate == today) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (msgDate == yesterday) {
      return 'Yesterday';
    } else {
      return '${dt.day}/${dt.month}/${dt.year.toString().substring(2)}';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 20),
        _buildHeader(),
        const SizedBox(height: 8),
        Expanded(child: _buildBody()),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HEADER
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        children: [
          // ── Search bar + total unread badge ──
          Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: const Color(0xFFFBC02D), width: 2),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black12,
                          blurRadius: 8,
                          offset: Offset(0, 3))
                    ],
                  ),
                  child: TextField(
                    onChanged: (val) => setState(() => searchQuery = val),
                    decoration: const InputDecoration(
                      hintText: 'Search name...',
                      prefixIcon: Icon(Icons.search, color: Color(0xFF8B0A1A)),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
              if (_totalUnread > 0) ...[
                const SizedBox(width: 10),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B0A1A),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                          color: const Color(0xFF8B0A1A).withOpacity(0.4),
                          blurRadius: 8,
                          offset: const Offset(0, 3))
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.mark_chat_unread_rounded,
                          color: Color(0xFFFBC02D), size: 14),
                      const SizedBox(width: 5),
                      Text(
                        _totalUnread > 99 ? '99+' : '$_totalUnread',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),

          // ── Tabs + create group button ──
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 45,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDF2F3),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(
                        color: const Color(0xFFFBC02D).withOpacity(0.5)),
                  ),
                  child: Row(
                    children: [
                      _buildTabItem('STUDENTS', 'student', _studentUnread),
                      _buildTabItem('TEACHERS', 'teacher', _teacherUnread),
                      _buildTabItem('GROUPS',   'group',   _groupUnread),
                    ],
                  ),
                ),
              ),
              if (currentUserRole == 'teacher') ...[
                const SizedBox(width: 10),
                Tooltip(
                  message: 'Create Group',
                  child: GestureDetector(
                    onTap: _showCreateGroupDialog,
                    child: Container(
                      height: 45, width: 45,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8B0A1A), Color(0xFFB71C1C)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                              color: const Color(0xFF8B0A1A).withOpacity(0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 3))
                        ],
                      ),
                      child: const Icon(Icons.group_add_rounded,
                          color: Colors.white, size: 22),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabItem(String label, String tabKey, int tabUnread) {
    final bool isSel = selectedTab == tabKey;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => selectedTab = tabKey),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSel ? const Color(0xFF8B0A1A) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(label,
                    style: TextStyle(
                        color: isSel ? Colors.white : const Color(0xFF8B0A1A),
                        fontWeight: FontWeight.bold,
                        fontSize: 10)),
              ),
              if (tabUnread > 0 && !isSel)
                Positioned(
                  top: -8, right: -4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                        color: Color(0xFFFBC02D), shape: BoxShape.circle),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      tabUnread > 99 ? '99+' : '$tabUnread',
                      style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF8B0A1A)),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (selectedTab == 'group') return _buildGroupsList();
    return _buildUsersList();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ USERS LIST — shows Hive cache instantly, live stream updates on top
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildUsersList() {
    // Use live data if available, else Hive cache
    final source = _users.isNotEmpty ? _users : _cachedUsers;

    if (source.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF8B0A1A)));
    }

    final List<UserProfile> list = source
        .where((u) =>
            u.uid != currentUserId &&
            u.role.toLowerCase() == selectedTab &&
            u.name.toLowerCase().contains(searchQuery.toLowerCase()))
        .toList();

    list.sort((a, b) {
      final int tA = _lastMessageTimes[a.uid] ?? 0;
      final int tB = _lastMessageTimes[b.uid] ?? 0;
      if (tA == 0 && tB == 0) return a.name.compareTo(b.name);
      return tB.compareTo(tA);
    });

    if (list.isEmpty) {
      return _buildEmptyState('No ${selectedTab}s found', Icons.search_off);
    }

    return ListView.builder(
      itemCount: list.length,
      padding: const EdgeInsets.fromLTRB(15, 5, 15, 100),
      physics: const BouncingScrollPhysics(),
      itemBuilder: (context, index) => _buildUserTile(list[index]),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // USER TILE
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildUserTile(UserProfile user) {
    final int    unread   = _unreadCounts[user.uid]     ?? 0;
    final int    lastTime = _lastMessageTimes[user.uid] ?? 0;
    final String lastMsg  = _lastMessages[user.uid]     ?? '';
    final String timeStr  = _formatTime(lastTime);
    final bool   hasChat  = lastTime > 0;
    final bool   hasUnread = unread > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: hasUnread ? const Color(0xFF8B0A1A) : const Color(0xFFFBC02D),
          width: hasUnread ? 2 : 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: hasUnread
                ? const Color(0xFF8B0A1A).withOpacity(0.08)
                : Colors.black.withOpacity(0.04),
            blurRadius: 6, offset: const Offset(0, 2),
          )
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: hasUnread
                  ? const Color(0xFF8B0A1A)
                  : const Color(0xFFFBC02D),
              width: 2,
            ),
          ),
          child: _cachedAvatar(user.profilePic, radius: 24),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(user.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight:
                          hasUnread ? FontWeight.w800 : FontWeight.w600,
                      color: Colors.black87,
                      fontSize: 14.5)),
            ),
            const SizedBox(width: 6),
            if (timeStr.isNotEmpty)
              Text(timeStr,
                  style: TextStyle(
                      fontSize: 11,
                      color: hasUnread
                          ? const Color(0xFF8B0A1A)
                          : Colors.grey[500],
                      fontWeight:
                          hasUnread ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  hasChat && lastMsg.isNotEmpty
                      ? lastMsg
                      : _userSubtitle(user),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 12,
                      color: hasUnread ? Colors.black87 : Colors.grey[500],
                      fontWeight:
                          hasUnread ? FontWeight.w600 : FontWeight.normal),
                ),
              ),
              const SizedBox(width: 6),
              if (hasUnread)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFBC02D),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF8B0A1A)),
                  ),
                ),
            ],
          ),
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              partnerId:   user.uid,
              partnerName: user.name,
              partnerPic:  user.profilePic,
              partnerDept: user.dept,
              receiverId:  user.uid,
            ),
          ),
        ),
      ),
    );
  }

  String _userSubtitle(UserProfile user) {
    final List<String> parts = [];
    if (user.dept.isNotEmpty)     parts.add(user.dept);
    if (user.semester.isNotEmpty) parts.add('Sem ${user.semester}');
    if (user.batch.isNotEmpty)    parts.add(user.batch);
    if (user.role.isNotEmpty)     parts.add(user.role);
    return parts.join(' • ');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ GROUPS LIST — shows Hive cache instantly
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildGroupsList() {
    final source = _groups.isNotEmpty ? _groups : _cachedGroups;

    if (source.isEmpty) {
      return _buildEmptyState(
        currentUserRole == 'teacher'
            ? 'No groups yet.\nTap \'+\' to create one!'
            : 'No groups yet.\nAsk your teacher to create one.',
        Icons.group_outlined,
      );
    }

    final filtered = source
        .where((g) => (g['name'] ?? '')
            .toString()
            .toLowerCase()
            .contains(searchQuery.toLowerCase()))
        .toList();

    if (filtered.isEmpty) {
      return _buildEmptyState('No groups match search', Icons.search_off);
    }

    return ListView.builder(
      itemCount: filtered.length,
      padding: const EdgeInsets.fromLTRB(15, 5, 15, 100),
      physics: const BouncingScrollPhysics(),
      itemBuilder: (context, index) => _buildGroupTile(filtered[index]),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GROUP TILE
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildGroupTile(Map<String, dynamic> data) {
    final String groupId   = data['_id']          ?? '';
    final String groupName = data['name']          ?? 'Unnamed Group';
    final String lastMsg   = data['lastMessage']   ?? '';
    final String groupPic  = data['groupPic']      ?? '';
    final int    lastTimeMs = (data['lastMessageTimeMs'] as num?)?.toInt() ?? 0;
    final String timeStr   = _formatTime(lastTimeMs);
    final List   members   = (data['members'] as List?) ?? [];
    final bool   isCreator = data['createdBy'] == currentUserId;

    return StreamBuilder<DatabaseEvent>(
      stream: FirebaseDatabase.instance
          .ref('GroupMessages/$groupId')
          .onValue,
      builder: (context, snap) {
        int groupUnread = 0;
        if (snap.hasData && snap.data!.snapshot.value != null) {
          try {
            final Map msgs = snap.data!.snapshot.value as Map;
            msgs.forEach((key, value) {
              if (value == null || value is! Map) return;
              final Map msg = value;
              if (msg['isRead'] == false &&
                  msg['senderId']?.toString() != currentUserId &&
                  msg['isDeleted'] != true) {
                groupUnread++;
              }
            });
          } catch (_) {}

          if (groupUnread != _groupUnread) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _groupUnread = groupUnread;
                  _totalUnread = _studentUnread + _teacherUnread + _groupUnread;
                });
              }
            });
          }
        }

        final bool hasUnread = groupUnread > 0;

        return GestureDetector(
          onTap: () {
            if (groupId.isEmpty) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GroupChatScreen(
                  groupId:         groupId,
                  groupName:       groupName,
                  groupPic:        groupPic,
                  currentUserRole: currentUserRole,
                ),
              ),
            );
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: hasUnread
                    ? const Color(0xFF8B0A1A)
                    : const Color(0xFFFBC02D),
                width: hasUnread ? 2 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: hasUnread
                      ? const Color(0xFF8B0A1A).withOpacity(0.08)
                      : Colors.black.withOpacity(0.04),
                  blurRadius: 6, offset: const Offset(0, 2),
                )
              ],
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              leading: Container(
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: const Color(0xFFFBC02D), width: 2)),
                child: groupPic.isNotEmpty
                    ? ClipOval(
                        child: CachedNetworkImage(
                          imageUrl: groupPic,
                          width: 48, height: 48, fit: BoxFit.cover,
                          placeholder: (_, __) => _groupInitial(groupName),
                          errorWidget: (_, __, ___) => _groupInitial(groupName),
                        ),
                      )
                    : _groupInitial(groupName),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(groupName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontWeight: hasUnread
                                      ? FontWeight.w800
                                      : FontWeight.w700,
                                  color: Colors.black87,
                                  fontSize: 14.5)),
                        ),
                        if (isCreator) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color:
                                  const Color(0xFF8B0A1A).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Admin',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: Color(0xFF8B0A1A),
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (timeStr.isNotEmpty)
                    Text(timeStr,
                        style: TextStyle(
                            fontSize: 11,
                            color: hasUnread
                                ? const Color(0xFF8B0A1A)
                                : Colors.grey[500],
                            fontWeight: hasUnread
                                ? FontWeight.bold
                                : FontWeight.normal)),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        lastMsg.isNotEmpty
                            ? lastMsg
                            : '${members.length} members',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                hasUnread ? Colors.black87 : Colors.grey[500],
                            fontWeight: hasUnread
                                ? FontWeight.w600
                                : FontWeight.normal),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (hasUnread)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFBC02D),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          groupUnread > 99 ? '99+' : '$groupUnread',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF8B0A1A)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _groupInitial(String name) => CircleAvatar(
        radius: 24,
        backgroundColor: const Color(0xFF8B0A1A),
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : 'G',
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      );

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ CACHED AVATAR
  // ─────────────────────────────────────────────────────────────────────────
  Widget _cachedAvatar(String url, {double radius = 24}) {
    final double size = radius * 2;
    if (url.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          width: size, height: size, fit: BoxFit.cover,
          placeholder: (_, __) => _defaultAvatar(radius),
          errorWidget: (_, __, ___) => _defaultAvatar(radius),
        ),
      );
    }
    return _defaultAvatar(radius);
  }

  Widget _defaultAvatar(double radius) => CircleAvatar(
        radius: radius,
        backgroundColor: Colors.grey[100],
        child: Icon(Icons.person,
            color: const Color(0xFF8B0A1A), size: radius * 0.8),
      );

  // ─────────────────────────────────────────────────────────────────────────
  // ✅ CREATE GROUP DIALOG — Name / Dept / Semester / Batch filters
  //    Values exact match with StudentSignupActivity
  // ─────────────────────────────────────────────────────────────────────────
  void _showCreateGroupDialog() {
    final TextEditingController groupNameCtrl    = TextEditingController();
    final TextEditingController memberSearchCtrl = TextEditingController();
    List<String> selectedMembers = [];
    String filterName   = '';
    String selectedDept = 'All';
    String selectedSem  = 'All';
    String selectedBatch = 'All';

    // ✅ Exact values from StudentSignupActivity
    final List<String> deptOptions = [
      'All', 'Computer Science', 'Zoology', 'Mathematics',
      'English', 'Urdu', 'Physics', 'Pol Science',
    ];
    final List<String> semOptions = [
      'All', '1st', '2nd', '3rd', '4th', '5th', '6th', '7th', '8th',
    ];
    final List<String> batchOptions = [
      'All', '2021', '2022', '2023', '2024', '2025',
    ];

    // Use cached users for dialog (instant, no extra fetch)
    final List<UserProfile> allUsers =
        _users.isNotEmpty ? _users : _cachedUsers;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) {
          // Apply filters
          final filtered = allUsers
              .where((u) => u.uid != currentUserId)
              .where((u) {
                if (filterName.isNotEmpty &&
                    !u.name
                        .toLowerCase()
                        .contains(filterName.toLowerCase())) return false;
                if (selectedDept != 'All' && u.dept != selectedDept)
                  return false;
                if (selectedSem != 'All' && u.semester != selectedSem)
                  return false;
                if (selectedBatch != 'All' && u.batch != selectedBatch)
                  return false;
                return true;
              })
              .toList();

          return Dialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            child: Container(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.88),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Header ──
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          colors: [Color(0xFF8B0A1A), Color(0xFFB71C1C)]),
                      borderRadius: BorderRadius.vertical(
                          top: Radius.circular(20)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.group_add_rounded,
                            color: Color(0xFFFBC02D), size: 24),
                        const SizedBox(width: 10),
                        const Text('Create New Group',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 17)),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: const Icon(Icons.close,
                              color: Colors.white70, size: 20),
                        ),
                      ],
                    ),
                  ),

                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── Group Name ──
                          TextField(
                            controller: groupNameCtrl,
                            decoration: InputDecoration(
                              labelText: 'Group Name',
                              labelStyle: const TextStyle(
                                  color: Color(0xFF8B0A1A)),
                              prefixIcon: const Icon(Icons.group,
                                  color: Color(0xFF8B0A1A)),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                    color: Color(0xFF8B0A1A), width: 2),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                    color: Color(0xFFFBC02D), width: 1.5),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),

                          // ── Member name search ──
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFDF2F3),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: const Color(0xFFFBC02D),
                                        width: 1.5),
                                  ),
                                  child: TextField(
                                    controller: memberSearchCtrl,
                                    onChanged: (val) =>
                                        setDState(() => filterName = val),
                                    decoration: const InputDecoration(
                                      hintText: 'Search by name...',
                                      prefixIcon: Icon(Icons.search,
                                          color: Color(0xFF8B0A1A), size: 20),
                                      border: InputBorder.none,
                                      contentPadding: EdgeInsets.symmetric(
                                          vertical: 10),
                                    ),
                                  ),
                                ),
                              ),
                              if (selectedMembers.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                      color: const Color(0xFF8B0A1A),
                                      borderRadius:
                                          BorderRadius.circular(20)),
                                  child: Text(
                                    '${selectedMembers.length} selected',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 12),

                          // ── Dept filter ──
                          _filterLabel('Department'),
                          const SizedBox(height: 6),
                          _filterChips(
                            options: deptOptions,
                            selected: selectedDept,
                            activeColor: const Color(0xFF8B0A1A),
                            onSelect: (v) =>
                                setDState(() => selectedDept = v),
                          ),
                          const SizedBox(height: 10),

                          // ── Semester filter ──
                          _filterLabel('Semester'),
                          const SizedBox(height: 6),
                          _filterChips(
                            options: semOptions,
                            selected: selectedSem,
                            activeColor: const Color(0xFFFBC02D),
                            activeTextColor: const Color(0xFF8B0A1A),
                            onSelect: (v) => setDState(() => selectedSem = v),
                          ),
                          const SizedBox(height: 10),

                          // ── Batch filter ──
                          _filterLabel('Batch'),
                          const SizedBox(height: 6),
                          _filterChips(
                            options: batchOptions,
                            selected: selectedBatch,
                            activeColor: Colors.blue.shade700,
                            onSelect: (v) =>
                                setDState(() => selectedBatch = v),
                          ),
                          const SizedBox(height: 14),

                          // ── Users header with clear button ──
                          Row(
                            children: [
                              _filterLabel('Add Members'),
                              const Spacer(),
                              if (selectedDept != 'All' ||
                                  selectedSem   != 'All' ||
                                  selectedBatch != 'All' ||
                                  filterName.isNotEmpty)
                                GestureDetector(
                                  onTap: () => setDState(() {
                                    selectedDept  = 'All';
                                    selectedSem   = 'All';
                                    selectedBatch = 'All';
                                    filterName    = '';
                                    memberSearchCtrl.clear();
                                  }),
                                  child: const Text('Clear filters',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF8B0A1A),
                                          fontWeight: FontWeight.bold)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          // ── User list (from cache — no FutureBuilder needed!) ──
                          SizedBox(
                            height: 260,
                            child: filtered.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.search_off,
                                            size: 40,
                                            color: Colors.grey[300]),
                                        const SizedBox(height: 8),
                                        Text('No users match filters',
                                            style: TextStyle(
                                                color: Colors.grey[400],
                                                fontSize: 13)),
                                      ],
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: filtered.length,
                                    itemBuilder: (ctx2, i) {
                                      final UserProfile u = filtered[i];
                                      final bool isSel =
                                          selectedMembers.contains(u.uid);
                                      return Container(
                                        margin: const EdgeInsets.only(
                                            bottom: 6),
                                        decoration: BoxDecoration(
                                          color: isSel
                                              ? const Color(0xFFFDF2F3)
                                              : Colors.grey[50],
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          border: Border.all(
                                            color: isSel
                                                ? const Color(0xFF8B0A1A)
                                                : Colors.grey[200]!,
                                            width: isSel ? 1.5 : 1,
                                          ),
                                        ),
                                        child: CheckboxListTile(
                                          dense: true,
                                          value: isSel,
                                          activeColor:
                                              const Color(0xFF8B0A1A),
                                          checkColor: Colors.white,
                                          title: Text(u.name,
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                          subtitle: Text(
                                            _userSubtitle(u),
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.black54),
                                          ),
                                          secondary: ClipOval(
                                            child: u.profilePic.isNotEmpty
                                                ? CachedNetworkImage(
                                                    imageUrl: u.profilePic,
                                                    width: 36, height: 36,
                                                    fit: BoxFit.cover,
                                                    placeholder: (_, __) =>
                                                        _defaultAvatar(18),
                                                    errorWidget:
                                                        (_, __, ___) =>
                                                            _defaultAvatar(18),
                                                  )
                                                : _defaultAvatar(18),
                                          ),
                                          onChanged: (val) {
                                            setDState(() {
                                              val == true
                                                  ? selectedMembers.add(u.uid)
                                                  : selectedMembers
                                                      .remove(u.uid);
                                            });
                                          },
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── Action buttons ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: Color(0xFFFBC02D), width: 1.5),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12),
                            ),
                            child: const Text('Cancel',
                                style: TextStyle(
                                    color: Color(0xFF8B0A1A))),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.check_rounded,
                                color: Colors.white, size: 18),
                            label: const Text('Create',
                                style: TextStyle(color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF8B0A1A),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12),
                            ),
                            onPressed: () async {
                              final name = groupNameCtrl.text.trim();
                              if (name.isEmpty) {
                                _showSnack('Please enter a group name');
                                return;
                              }
                              if (selectedMembers.isEmpty) {
                                _showSnack('Select at least one member');
                                return;
                              }
                              Navigator.pop(ctx);
                              await _createGroup(name, selectedMembers);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FILTER HELPERS
  // ─────────────────────────────────────────────────────────────────────────
  Widget _filterLabel(String text) => Text(
        text,
        style: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54),
      );

  Widget _filterChips({
    required List<String> options,
    required String selected,
    required Color activeColor,
    Color activeTextColor = Colors.white,
    required void Function(String) onSelect,
  }) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final String opt = options[i];
          final bool   sel = selected == opt;
          return GestureDetector(
            onTap: () => onSelect(opt),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color:  sel ? activeColor : Colors.grey[100],
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: sel ? activeColor : Colors.grey[300]!),
              ),
              child: Text(opt,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: sel ? activeTextColor : Colors.black54)),
            ),
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CREATE GROUP
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _createGroup(String groupName, List<String> members) async {
    try {
      final List<String> allMembers = [...members, currentUserId];
      await FirebaseFirestore.instance.collection('Groups').add({
        'name':            groupName,
        'createdBy':       currentUserId,
        'members':         allMembers,
        'createdAt':       FieldValue.serverTimestamp(),
        'lastMessage':     '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'groupPic':        '',
        'isAdminOnly':     false,
      });
      _showSnack("✅ Group '$groupName' created!");
      setState(() => selectedTab = 'group');
    } catch (e) {
      _showSnack('Error: $e');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF8B0A1A),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Widget _buildEmptyState(String message, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 60, color: Colors.grey[300]),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[400], fontSize: 14)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ✅ UserProfile Model — signup se exact match
// ─────────────────────────────────────────────────────────────────────────────
class UserProfile {
  final String uid;
  final String name;
  final String email;
  final String profilePic;
  final String dept;
  final String role;
  final String semester; // Firestore: 'semester' | values: '1st'..'8th'
  final String batch;    // Firestore: 'batch'    | values: '2021'..'2025'

  UserProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.profilePic,
    required this.dept,
    required this.role,
    required this.semester,
    required this.batch,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map, String id) {
    return UserProfile(
      uid:        id,
      name:       map['name']             ?? '',
      email:      map['email']            ?? '',
      profilePic: map['profilePic']       ?? '',
      dept:       map['dept']             ?? '',
      role:       map['role']             ?? 'student',
      semester:   map['semester']?.toString() ?? '', // ✅ 'semester' not 'sem'
      batch:      map['batch']?.toString()    ?? '',
    );
  }
}