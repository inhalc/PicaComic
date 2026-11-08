import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:pdf/widgets.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/tools/ui_state.dart';

Future<void> createPdfFromComic({
  required String title,
  required String comicPath,
  required String savePath,
  required ByteData font,
  List<String>? chapters,
  List<int>? chapterIndexes,
}) async{
  final pdf = Document(
    theme: ThemeData(
      defaultTextStyle: TextStyle(
        font: Font.ttf(font)
      )
    )
  );

  // add cover
  var imageData = await File("$comicPath/cover.jpg").readAsBytes();
  pdf.addPage(Page(
    build: (Context context) {
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 100,
            child: Center(
              child: Text(title, style: const TextStyle(fontSize: 20)),
            )
          ),
          Expanded(
            child: Image(MemoryImage(imageData), fit: BoxFit.contain)
          )
        ]
      );
    },
  ));

  bool multiChapters = !(File("$comicPath/0.jpg").existsSync()
      || File("$comicPath/0.png").existsSync()
      || File("$comicPath/0.webp").existsSync()
      || File("$comicPath/0.jpeg").existsSync()
      || File("$comicPath/0.gif").existsSync());

  // 排序/过滤交给纯函数，避免 .DS_Store、Thumbs.db 或任何非数字文件名
  // 触发 int.parse 的 FormatException 导致导出失败 (#53)。
  List<File> reorderFiles(List<FileSystemEntity> files) {
    final paths = files.whereType<File>().map((e) => e.path).toList();
    return reorderImagePaths(paths).map((p) => File(p)).toList();
  }

  if(!multiChapters){
    var files = Directory(comicPath).listSync();

    for (var file in reorderFiles(files)){
      var imageData = await file.readAsBytes();
      pdf.addPage(Page(
        build: (Context context) {
          return Image(MemoryImage(imageData), fit: BoxFit.contain);
        },
      ));
    }
  } else {
    for (int current = 0; current < chapterIndexes!.length; current++){
      var directory = Directory("$comicPath/${chapterIndexes[current]+1}");
      // add chapter title
      pdf.addPage(Page(
        build: (Context context) {
          return Center(
            child: Text(chapters![chapterIndexes[current]],
                style: const TextStyle(fontSize: 20)),
          );
        },
      ));

      var files = directory.listSync();

      for (var file in reorderFiles(files)){
        var imageData = await file.readAsBytes();
        pdf.addPage(Page(
          build: (Context context) {
            return Image(MemoryImage(imageData), fit: BoxFit.contain);
          },
        ));
      }
    }
  }

  final file = File(savePath);
  await file.writeAsBytes(await pdf.save());
}

Future<void> createPdfFromComicWithIsolate({
  required String title,
  required String comicPath,
  required String savePath,
  List<String>? chapters,
  List<int>? chapterIndexes,
}) async{
  var fontData = await _loadFont();

  return Isolate.run(() => createPdfFromComic(
    title: title,
    comicPath: comicPath,
    savePath: savePath,
    font: fontData,
    chapters: chapters,
    chapterIndexes: chapterIndexes
  ));
}

Future<ByteData> _loadFont() async{
  if(Platform.isWindows) {
    return await rootBundle.load("fonts/NotoSansSC-Regular.ttf");
  }
  var fontFile = File("${App.dataPath}/font.ttf");
  if(!fontFile.existsSync()){
    throw Exception("Font file not found");
  }
  return fontFile.readAsBytes().then((value) => ByteData.sublistView(value));
}