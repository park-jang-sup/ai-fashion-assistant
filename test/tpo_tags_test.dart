// TpoTags.all/labels의 구조적 불변식 단위 테스트.
// calendar_record_sheet.dart의 initState가 TpoTags.labels.last를 기본값으로
// 쓰고, TpoTags.byLabel의 orElse가 all.last로 폴백하므로, 두 리스트의
// 순서·내용이 어긋나거나 마지막 원소가 '일상'이 아니게 되면 조용히 깨진다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_fashion_assistant/constants/tpo_tags.dart';

void main() {
  group('TpoTags', () {
    test('labels는 all과 순서·내용이 정확히 일치한다', () {
      expect(TpoTags.labels, TpoTags.all.map((t) => t.label).toList());
    });

    test('마지막 원소는 항상 일상이다(기본값/폴백 의존)', () {
      expect(TpoTags.labels.last, '일상');
      expect(TpoTags.all.last.label, '일상');
    });

    test('byLabel은 알 수 없는 라벨을 일상으로 폴백한다', () {
      expect(TpoTags.byLabel('존재하지않는태그').label, '일상');
    });

    test('포멀 격식대가 최소 하나는 실제로 존재한다(도달 가능한 등급)', () {
      expect(TpoTags.all.any((t) => t.formalityHint == '포멀'), isTrue);
    });

    test('결혼식/면접/경조사는 포멀 격식이다', () {
      for (final label in ['결혼식', '면접', '경조사']) {
        expect(TpoTags.byLabel(label).formalityHint, '포멀', reason: label);
      }
    });
  });
}
