import 'dart:convert';
import 'dart:io';

import 'package:pica_comic/tools/extensions.dart';

extension FileSystemEntityExt on FileSystemEntity{
  String get name {
    var path = this.path;
    if(path.endsWith('/') || path.endsWith('\\')){
      path = path.substring(0, path.length-1);
    }

    int i = path.length - 1;

    while(i >= 0 && path[i] != '\\' && path[i] != '/'){
      i--;
    }

    return path.substring(i+1);
  }

  Future<void> deleteIgnoreError({bool recursive = false}) async{
    try{
      await delete(recursive: recursive);
    }catch(e){
      // ignore
    }
  }
}

extension FileExtension on File{
  /// Get file size information in MB
  double getMBSizeSync(){
    var bytes = lengthSync();
    return bytes/1024/1024;
  }

  String get extension => path.split('.').last;
}

extension DirectoryExtension on Directory{
  /// Get directory size information in MB
  ///
  /// if directory is not exist, return 0;
  double getMBSizeSync(){
    if(!existsSync()) return 0;
    double total = 0;
    for(var f in listSync(recursive: true)){
      if(FileSystemEntity.typeSync(f.path)==FileSystemEntityType.file){
        total += File(f.path).lengthSync()/1024/1024;
      }
    }
    return total;
  }

  Future<int> get size async{
    if(!existsSync()) return 0;
    int total = 0;
    // `listSync(recursive: true)` materialises every entry in one list. With
    // tens of thousands of cached pages that alone was enough to OOM the
    // isolate (issues #202 / #259). `list()` streams directory by directory.
    await for(final entity in list(recursive: true)){
      if(entity is File){
        try {
          total += await entity.length();
        } catch (_) {
          // A file can be deleted by the cache eviction while we are counting.
        }
      }
    }
    return total;
  }

  Directory renameX(String newName){
    newName = sanitizeFileName(newName);
    return renameSync(path.replaceLast(name, newName));
  }
}

bool _isDigitCodeUnit(int code) => code >= 0x30 && code <= 0x39;

/// Natural file-name comparison: `2.jpg` sorts before `10.jpg`, so a comic
/// with hundreds of pages keeps its original order (#262 / #300).
int compareNaturalFileName(String a, String b) {
  int i = 0;
  int j = 0;
  while (i < a.length && j < b.length) {
    final aIsDigit = _isDigitCodeUnit(a.codeUnitAt(i));
    final bIsDigit = _isDigitCodeUnit(b.codeUnitAt(j));
    if (aIsDigit && bIsDigit) {
      final aStart = i;
      final bStart = j;
      while (i < a.length && _isDigitCodeUnit(a.codeUnitAt(i))) {
        i++;
      }
      while (j < b.length && _isDigitCodeUnit(b.codeUnitAt(j))) {
        j++;
      }
      final aValue = int.tryParse(a.substring(aStart, i)) ?? 0;
      final bValue = int.tryParse(b.substring(bStart, j)) ?? 0;
      if (aValue != bValue) {
        return aValue.compareTo(bValue);
      }
    } else {
      final aCode = a.codeUnitAt(i);
      final bCode = b.codeUnitAt(j);
      if (aCode != bCode) {
        return aCode.compareTo(bCode);
      }
      i++;
      j++;
    }
  }
  return (a.length - i).compareTo(b.length - j);
}

String sanitizeFileName(String fileName) {
  const maxLength = 255;
  final invalidChars = RegExp(r'[<>:"/\\|?*]');
  final sanitizedFileName = fileName.replaceAll(invalidChars, ' ');
  var trimmedFileName = sanitizedFileName.trim();
  if (trimmedFileName.isEmpty) {
    throw Exception('Invalid File Name: Empty length.');
  }
  while(true){
    final bytes = utf8.encode(trimmedFileName);
    if (bytes.length > maxLength) {
      trimmedFileName = trimmedFileName.substring(0, trimmedFileName.length-1);
    }else{
      break;
    }
  }
  return trimmedFileName;
}

String findValidDirectoryName(String path, String directory) {
  var name = sanitizeFileName(directory);
  var dir = Directory("$path/$name");
  var i = 1;
  while(dir.existsSync()){
    name = sanitizeFileName("$directory($i)");
    dir = Directory("$path/$name");
    i++;
  }
  return name;
}