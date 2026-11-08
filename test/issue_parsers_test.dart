import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/issue_parsers.dart';

void main() {
  test('parseLastPage 只取 page 参数，忽略含数字的关键词 (#230)', () {
    expect(
        parseLastPage('/search/?q=383963833833822383382382438396462&page=3'),
        3);
  });

  test('parseLastPage 对 page 后超长数字返回 1 (#230)', () {
    expect(parseLastPage('/search/?page=383963833833822383382382438396462'),
        1);
  });

  test('parseLastPage 对 null / 空 / 无 page 参数返回 1 (#230)', () {
    expect(parseLastPage(null), 1);
    expect(parseLastPage(''), 1);
    expect(parseLastPage('/search/?q=abc'), 1);
  });

  test('parseLastPage 正常 ?page=12 返回 12 (#230)', () {
    expect(parseLastPage('/search/?q=abc&page=12'), 12);
  });

  test('applyAutoLanguage 首次追加 (#277)', () {
    expect(applyAutoLanguage('foo', true, 1), 'foo language:chinese');
  });

  test('applyAutoLanguage 二次搜索不重复追加 (#277)', () {
    expect(applyAutoLanguage('foo language:chinese', true, 1),
        'foo language:chinese');
  });

  test('applyAutoLanguage 已含旧 language 后缀被替换 (#277)', () {
    expect(applyAutoLanguage('foo language:english', true, 3),
        'foo language:japanese');
  });

  test('applyAutoLanguage langSetting=0 不加 (#277)', () {
    expect(applyAutoLanguage('foo', true, 0), 'foo');
  });

  test('applyAutoLanguage 非法值不加 (#277)', () {
    expect(applyAutoLanguage('foo', true, 99), 'foo');
    expect(applyAutoLanguage('foo', true, -1), 'foo');
  });

  test('applyAutoLanguage 未启用筛选时保留用户手输的 language 后缀 (#277)', () {
    // 切到不支持语言筛选的漫画源时，不能把用户自己输入的条件悄悄删掉。
    expect(applyAutoLanguage('foo language:japanese', false, 1),
        'foo language:japanese');
    expect(applyAutoLanguage('foo language:japanese', true, 0),
        'foo language:japanese');
  });

  test('parseFavoriteNames 保留名称里的数量文本 (#39)', () {
    final names = parseFavoriteNames(['My Folder (42)']);
    expect(names.first, 'My Folder (42)');
    expect(names.length, 10);
  });

  test('parseFavoriteNames 输入 9 项返回恰好 10 项且不抛异常 (#39)', () {
    final names =
        parseFavoriteNames(List.generate(9, (i) => 'Folder $i ($i)'));
    expect(names.length, 10);
  });

  test('parseFavoriteNames 输入 10 项返回恰好 10 项且不抛异常 (#39)', () {
    final names =
        parseFavoriteNames(List.generate(10, (i) => 'Folder $i ($i)'));
    expect(names.length, 10);
  });

  test('parseFavoriteNames 输入 11 项返回恰好 10 项且不抛异常 (#39)', () {
    final names =
        parseFavoriteNames(List.generate(11, (i) => 'Folder $i ($i)'));
    expect(names.length, 10);
  });

  test('parseFavoriteNames 不足补齐 / 超过截断 (#39)', () {
    final short = parseFavoriteNames(['A (1)', 'B (2)']);
    expect(short[0], 'A (1)');
    expect(short[1], 'B (2)');
    expect(short[2], 'Favorite 2');
    expect(short[9], 'Favorite 9');

    final long = parseFavoriteNames(List.generate(12, (i) => 'F$i ($i)'));
    expect(long.length, 10);
    expect(long.last, 'F9 (9)');
  });

  test('resolveTermAndLanguage 保留完整 female 标签而不是首字符 (#280)', () {
    final r = resolveTermAndLanguage('female:humiliation', 'chinese');
    expect(r.tag, 'female:humiliation');
    expect(r.tag, isNot('f'));
    expect(r.area, 'tag');
    expect(r.language, 'chinese');
  });

  test('resolveTermAndLanguage 容忍标签内含冒号 (#280)', () {
    final r = resolveTermAndLanguage('tag:foo:bar', 'all');
    expect(r.tag, 'foo:bar');
  });
}
