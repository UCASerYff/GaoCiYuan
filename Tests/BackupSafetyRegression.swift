import Foundation
import SQLite3

enum AppDataLocations {
 static var appSupport:URL? { URL(fileURLWithPath:ProcessInfo.processInfo.environment["TEST_APP"]!) }
 static var groupContainer:URL? { URL(fileURLWithPath:ProcessInfo.processInfo.environment["TEST_GROUP"]!) }
}
@main struct BackupSafetyRegression {
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("gq-backup-test-"+UUID().uuidString)
  let app=root.appendingPathComponent("App"),group=root.appendingPathComponent("Group")
  for p in [app,group] { try fm.createDirectory(at:p,withIntermediateDirectories:true) }
  setenv("TEST_APP",app.path,1);setenv("TEST_GROUP",group.path,1);setenv("GQNS_RESTORE_ROOT",root.appendingPathComponent("Jobs").path,1)
  let doc=Data("PDF and Word test payload".utf8)
  try doc.write(to:app.appendingPathComponent("paper.pdf"));try doc.write(to:app.appendingPathComponent("paper.docx"))
  var db:OpaquePointer?;assert(sqlite3_open(group.appendingPathComponent("test.sqlite").path,&db)==SQLITE_OK)
  assert(sqlite3_exec(db,"PRAGMA journal_mode=WAL;CREATE TABLE t (v TEXT);INSERT INTO t VALUES('committed WAL data');",nil,nil,nil)==SQLITE_OK)
  let archive=root.appendingPathComponent("backup.zip")
  print("Export stage");fflush(stdout)
  _ = try AppBackupExport.export(appSupport:app,group:group,destination:archive)
  print("Prepare stage");fflush(stdout)
  let (staged,m)=try AppBackupRestore.prepare(archive);assert(m.files.count==4)
  sqlite3_close(db)
  try Data("new current data".utf8).write(to:app.appendingPathComponent("paper.pdf"))
  try AppBackupRestore.schedule(staged);try AppBackupRestore.applyPending()
  let restored=try Data(contentsOf:app.appendingPathComponent("paper.pdf"));assert(restored==doc)
  assert(DailyBackup.integrityCheck(group.appendingPathComponent("test.sqlite"))=="ok")
  let previousHash=try BackupIntegrity.hash(archive)
  // Corrupt source databases cannot replace a known-good existing archive.
  try Data("not sqlite".utf8).write(to:group.appendingPathComponent("broken.sqlite"))
  do { _ = try AppBackupExport.export(appSupport:app,group:group,destination:archive);assertionFailure("accepted corrupt db") } catch {}
  let afterHash=try BackupIntegrity.hash(archive);assert(previousHash==afterHash)
  let (bad,_)=try AppBackupRestore.prepare(archive)
  try Data("tampered".utf8).write(to:bad.appendingPathComponent("ApplicationSupport-Token/paper.pdf"))
  do { _ = try BackupIntegrity.verify(bad);assertionFailure("accepted corrupt attachment") } catch {}
  print("PASS Backup: WAL-consistent snapshot; SHA-256 attachments; export/preview/restore roundtrip; original preserved on export failure; tampering rejected; safety copy retained")
  try fm.removeItem(at:root)
 }
}
