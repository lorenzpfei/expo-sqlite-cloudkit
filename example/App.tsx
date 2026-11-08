import { SQLiteProvider, useSQLiteContext, type SQLiteDatabase } from 'expo-sqlite';
import {
  addChangeListener,
  addStatusListener,
  configureSync,
  getStatus,
  syncNow,
  type SyncStatus,
} from 'expo-sqlite-cloudkit';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  FlatList,
  PlatformColor,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

const DATABASE_NAME = 'notes.db';
const CONTAINER_IDENTIFIER = process.env.EXPO_PUBLIC_ICLOUD_CONTAINER ?? 'iCloud.com.example.syncnotes';

type Note = { id: string; title: string; updated_at: number };

async function migrate(db: SQLiteDatabase) {
  await db.execAsync(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL DEFAULT '',
      updated_at INTEGER NOT NULL,
      deleted_at INTEGER
    );
  `);
  await configureSync({
    databaseName: DATABASE_NAME,
    containerIdentifier: CONTAINER_IDENTIFIER,
    tables: [
      {
        name: 'notes',
        primaryKey: ['id'],
        updatedAtColumn: 'updated_at',
        deletedAtColumn: 'deleted_at',
        encryptedColumns: ['body'],
      },
    ],
  });
}

export default function App() {
  return (
    <SQLiteProvider databaseName={DATABASE_NAME} onInit={migrate}>
      <Notes />
      <StatusBar style="auto" />
    </SQLiteProvider>
  );
}

function Notes() {
  const db = useSQLiteContext();
  const [notes, setNotes] = useState<Note[]>([]);
  const [draft, setDraft] = useState('');
  const [editing, setEditing] = useState<{ id: string; title: string } | null>(null);
  const [status, setStatus] = useState<SyncStatus | null>(null);

  const load = useCallback(async () => {
    setNotes(
      await db.getAllAsync<Note>(
        'SELECT id, title, updated_at FROM notes WHERE deleted_at IS NULL ORDER BY updated_at DESC',
      ),
    );
    setStatus(await getStatus());
  }, [db]);

  useEffect(() => {
    load();
    const changes = addChangeListener(load);
    const statuses = addStatusListener(setStatus);
    return () => {
      changes.remove();
      statuses.remove();
    };
  }, [load]);

  const add = async () => {
    const title = draft.trim();
    if (!title) return;
    await db.runAsync('INSERT INTO notes (id, title, updated_at) VALUES (?, ?, ?)', [
      randomId(),
      title,
      Date.now(),
    ]);
    setDraft('');
    await load();
  };

  const save = async () => {
    if (!editing) return;
    await db.runAsync('UPDATE notes SET title = ?, updated_at = ? WHERE id = ?', [
      editing.title.trim() || 'Untitled',
      Date.now(),
      editing.id,
    ]);
    setEditing(null);
    await load();
  };

  const softDelete = async (id: string) => {
    const now = Date.now();
    await db.runAsync('UPDATE notes SET deleted_at = ?, updated_at = ? WHERE id = ?', [now, now, id]);
    await load();
  };

  const hardDelete = async (id: string) => {
    await db.runAsync('DELETE FROM notes WHERE id = ?', [id]);
    await load();
  };

  const sync = async () => {
    try {
      await syncNow();
    } catch (error) {
      Alert.alert('Sync failed', String(error));
    }
    await load();
  };

  return (
    <SafeAreaView style={styles.screen}>
      <View style={styles.header}>
        <Text style={styles.title}>Notes</Text>
        <Pressable onPress={sync} hitSlop={12}>
          <Text style={styles.action}>Sync now</Text>
        </Pressable>
      </View>
      <SyncSummary status={status} />
      <View style={styles.composer}>
        <TextInput
          style={styles.input}
          placeholder="New note"
          placeholderTextColor={PlatformColor('placeholderText')}
          value={draft}
          onChangeText={setDraft}
          onSubmitEditing={add}
          returnKeyType="done"
        />
        <Pressable onPress={add} hitSlop={8}>
          <Text style={styles.action}>Add</Text>
        </Pressable>
      </View>
      <FlatList
        data={notes}
        keyExtractor={(note) => note.id}
        contentContainerStyle={styles.list}
        ListEmptyComponent={<Text style={styles.empty}>No notes yet</Text>}
        renderItem={({ item }) =>
          editing?.id === item.id ? (
            <View style={styles.row}>
              <TextInput
                style={[styles.input, styles.rowText]}
                value={editing.title}
                onChangeText={(title) => setEditing({ id: item.id, title })}
                onSubmitEditing={save}
                autoFocus
              />
              <Pressable onPress={save} hitSlop={8}>
                <Text style={styles.action}>Save</Text>
              </Pressable>
            </View>
          ) : (
            <View style={styles.row}>
              <Pressable style={styles.rowText} onPress={() => setEditing({ id: item.id, title: item.title })}>
                <Text style={styles.noteTitle}>{item.title}</Text>
                <Text style={styles.secondary}>{new Date(item.updated_at).toLocaleString()}</Text>
              </Pressable>
              <Pressable
                onPress={() => softDelete(item.id)}
                onLongPress={() => hardDelete(item.id)}
                hitSlop={8}
              >
                <Text style={styles.destructive}>Delete</Text>
              </Pressable>
            </View>
          )
        }
      />
    </SafeAreaView>
  );
}

function SyncSummary({ status }: { status: SyncStatus | null }) {
  if (!status) return null;
  const lastSync = status.lastSyncAt ? new Date(status.lastSyncAt).toLocaleTimeString() : 'never';
  return (
    <View style={styles.summary}>
      <Text style={styles.secondary}>
        iCloud: {status.account} · {status.syncing ? 'syncing' : `last sync ${lastSync}`} · {status.pendingChanges}{' '}
        pending
      </Text>
      {status.lastError ? <Text style={styles.error}>{status.lastError}</Text> : null}
    </View>
  );
}

function randomId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: PlatformColor('systemGroupedBackground') },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingTop: 12,
  },
  title: { fontSize: 34, fontWeight: '700', color: PlatformColor('label') },
  summary: { paddingHorizontal: 16, paddingTop: 4, gap: 2 },
  composer: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    margin: 16,
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderRadius: 10,
    backgroundColor: PlatformColor('secondarySystemGroupedBackground'),
  },
  input: { flex: 1, fontSize: 17, color: PlatformColor('label') },
  list: { marginHorizontal: 16, borderRadius: 10, overflow: 'hidden' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 12,
    backgroundColor: PlatformColor('secondarySystemGroupedBackground'),
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: PlatformColor('separator'),
  },
  rowText: { flex: 1, gap: 2 },
  noteTitle: { fontSize: 17, color: PlatformColor('label') },
  secondary: { fontSize: 13, color: PlatformColor('secondaryLabel') },
  error: { fontSize: 13, color: PlatformColor('systemRed') },
  empty: { padding: 16, fontSize: 15, color: PlatformColor('secondaryLabel'), textAlign: 'center' },
  action: { fontSize: 17, color: PlatformColor('systemBlue') },
  destructive: { fontSize: 17, color: PlatformColor('systemRed') },
});
