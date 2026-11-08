import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/ui_state.dart';

void main() {
  group('shouldPopOnEscape (#75)', () {
    test('四种布尔组合', () {
      expect(shouldPopOnEscape(rootCanPop: true, mainCanPop: true), isTrue);
      expect(shouldPopOnEscape(rootCanPop: true, mainCanPop: false), isTrue);
      expect(shouldPopOnEscape(rootCanPop: false, mainCanPop: true), isTrue);
      expect(shouldPopOnEscape(rootCanPop: false, mainCanPop: false), isFalse);
    });
  });

  group('parseFavoritesPageState (#252)', () {
    test('"1;;" 未选择收藏夹', () {
      final s = parseFavoritesPageState('1;;');
      expect(s.selectingFolder, isTrue);
      expect(s.isNetwork, isNull);
      expect(s.current, isNull);
      expect(s.hasDangerousCombination, isFalse);
    });

    test('"0;1;folder" 网络收藏夹', () {
      final s = parseFavoritesPageState('0;1;folder');
      expect(s.selectingFolder, isFalse);
      expect(s.isNetwork, isTrue);
      expect(s.current, 'folder');
      expect(s.hasDangerousCombination, isFalse);
    });

    test('"0;;foo" 不产生 current 非空而 isNetwork 为 null 的危险组合', () {
      final s = parseFavoritesPageState('0;;foo');
      expect(s.current, 'foo');
      expect(s.isNetwork, isFalse);
      expect(s.hasDangerousCombination, isFalse);
      expect(s.current != null && s.isNetwork == null, isFalse);
    });

    test('字段缺失不越界、不产生危险组合', () {
      for (final raw in ['', '0', '0;', '0;0', '0;1', '1', ';', ';;']) {
        final s = parseFavoritesPageState(raw);
        expect(s.hasDangerousCombination, isFalse, reason: 'raw=$raw');
      }
      expect(parseFavoritesPageState('').current, isNull);
      expect(parseFavoritesPageState('0').isNetwork, isNull);
    });

    test('本地收藏夹名可包含分号', () {
      final s = parseFavoritesPageState('0;0;my;folder');
      expect(s.isNetwork, isFalse);
      expect(s.current, 'my;folder');
      expect(s.hasDangerousCombination, isFalse);
    });
  });

  group('PaginationState (#169)', () {
    test('成功且非空推进 current', () {
      final s = PaginationState(current: 1);
      s.applyResult(outcome: PageLoadOutcome.successNonEmpty);
      expect(s.current, 2);
      expect(s.emptyPageCount, 0);
      expect(s.canRequestNext, isTrue);
    });

    test('错误不推进 current 且停止自动加载', () {
      final s = PaginationState(current: 5);
      s.applyResult(
          outcome: PageLoadOutcome.error, errorMessage: 'boom');
      expect(s.current, 5);
      expect(s.message, 'boom');
      expect(s.stopped, isTrue);
      expect(s.canRequestNext, isFalse);
    });

    test('连续空页无条件收敛到 current（即使 maxPage 已非 null）', () {
      final s = PaginationState(current: 6, maxPage: 999);
      expect(s.canRequestNext, isTrue);
      s.applyResult(
          outcome: PageLoadOutcome.emptyPage,
          serverMaxPage: 999,
          emptyPageThreshold: 2);
      expect(s.current, 6);
      expect(s.canRequestNext, isTrue);
      s.applyResult(
          outcome: PageLoadOutcome.emptyPage,
          serverMaxPage: 999,
          emptyPageThreshold: 2);
      expect(s.maxPage, 6);
      expect(s.stopped, isTrue);
      expect(s.canRequestNext, isFalse);
    });

    test('成功页会用服务端 maxPage, 到达后不再请求', () {
      final s = PaginationState(current: 2, maxPage: 3);
      expect(s.canRequestNext, isTrue);
      s.applyResult(
          outcome: PageLoadOutcome.successNonEmpty, serverMaxPage: 3);
      expect(s.current, 3);
      expect(s.canRequestNext, isFalse);
    });

    test('current >= maxPage 不再请求', () {
      expect(PaginationState(current: 3, maxPage: 3).canRequestNext, isFalse);
      expect(PaginationState(current: 4, maxPage: 3).canRequestNext, isFalse);
      expect(PaginationState(current: 2, maxPage: 3).canRequestNext, isTrue);
    });

    test('错误后即便未给 message 也因 stopped 停止', () {
      final s = PaginationState(current: 1);
      s.applyResult(outcome: PageLoadOutcome.error);
      expect(s.stopped, isTrue);
      expect(s.canRequestNext, isFalse);
    });
  });

  group('reorderImagePaths (#53)', () {
    test('数字名 1,10,2 顺序正确', () {
      expect(
        reorderImagePaths(['/c/10.jpg', '/c/1.jpg', '/c/2.png']),
        ['/c/1.jpg', '/c/2.png', '/c/10.jpg'],
      );
    });

    test('.DS_Store / info.json / cover.jpg 被过滤且不抛异常', () {
      expect(
        reorderImagePaths([
          '/c/2.jpg',
          '/c/.DS_Store',
          '/c/info.json',
          '/c/cover.jpg',
          '/c/1.jpg',
        ]),
        ['/c/1.jpg', '/c/2.jpg'],
      );
    });

    test('Thumbs.db 等非图片扩展名被过滤', () {
      expect(
        reorderImagePaths(['/c/Thumbs.db', '/c/1.jpg', '/c/2.jpg']),
        ['/c/1.jpg', '/c/2.jpg'],
      );
    });

    test('非数字名稳定兜底, 按名称字符串排且不抛异常', () {
      expect(
        reorderImagePaths(['/c/z.png', '/c/1.jpg', '/c/a.jpg', '/c/10.jpg']),
        ['/c/1.jpg', '/c/10.jpg', '/c/a.jpg', '/c/z.png'],
      );
    });

    test('保持跨章节完整路径语义', () {
      expect(
        reorderImagePaths(['/comic/2/2.jpg', '/comic/2/1.jpg']),
        ['/comic/2/1.jpg', '/comic/2/2.jpg'],
      );
    });

    test('数字名的未知图片扩展名仍保留 (#53 回归)', () {
      // 漫画源可能保存为 .avif / .jxl / 自定义扩展名，不能因为不在
      // 白名单里就整页丢掉。
      expect(
        reorderImagePaths(['/c/2.xyz', '/c/1.xyz', '/c/3.avif']),
        ['/c/1.xyz', '/c/2.xyz', '/c/3.avif'],
      );
    });
  });
}
