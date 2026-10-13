import 'package:gqlify_runtime/testing.dart';
import 'package:test/test.dart';

import 'fixtures/polymorphism/fragments.graphql.dart';
import 'fixtures/polymorphism/operations.graphql.dart';
import 'fixtures/polymorphism/schema.graphql.dart';

/// Works with every selection spreading `MediaFields`.
String media(MediaFields m) => switch (m) {
  MediaFields$Image(:final width) => 'image ${m.url} ${width}px',
  _ => 'media ${m.url}',
};

void main() {
  GqlifyClient client(Map<String, Object?> data) =>
      GqlifyClient(transport: MockTransport.fixed({'data': data}));

  test('interface fragment spread inside a union selection', () async {
    final feed = (await client({
      'feed': [
        {'__typename': 'Image', 'kind': 'Image', 'url': 'a.png', 'width': 3},
        {'__typename': 'Video', 'kind': 'Video', 'url': 'b.mp4'},
        {'__typename': 'Text', 'kind': 'Text', 'body': 'hi'},
      ],
    }).feed()).feed;

    expect(
      [
        for (final block in feed)
          switch (block) {
            FeedFeed$Image() || FeedFeed$Video() => media(block as MediaFields),
            FeedFeed$Text(:final body) => 'text $body',
            FeedFeed$Other(:final typename) => 'other $typename',
          },
      ],
      ['image a.png 3px', 'media b.mp4', 'text hi'],
    );
    expect(feed.map((b) => b.kind), ['Image', 'Video', 'Text']);
  });

  test('conditional fragment spreads produce optional fields', () async {
    final text = (await client({
      'node': {'__typename': 'Text', 'id': 't1'},
    }).nodeById(id: 't1', withText: false)).node!;
    expect(text, isA<NodeByIdNode$Text>());
    expect((text as NodeByIdNode$Text).body, isNull);
    expect(text, isNot(isA<TextBody>()));

    final video = (await client({
      'node': {'__typename': 'Video', 'id': 'v1', 'url': 'v.mp4'},
    }).nodeById(id: 'v1', withText: true)).node!;
    expect(media(video as MediaFields), 'media v.mp4');
  });

  test('interfaces implementing interfaces', () async {
    final list = (await client({
      'media': [
        {'__typename': 'Video', 'id': 'v', 'url': 'v.mp4', 'duration': 1},
        {'__typename': 'Image', 'id': 'i', 'url': 'i.png'},
      ],
    }).mediaList()).media;
    expect((list.first as MediaListMedia$Video).duration, 1.0);
    expect(list.last, isA<MediaListMedia$Other>());
    expect(list.map((m) => m.url), ['v.mp4', 'i.png']);
  });

  test('nested polymorphism inside a fragment', () async {
    final page = (await client({
      'page': {
        'id': 'p',
        'title': 'Home',
        'blocks': [
          {'__typename': 'Text', 'body': 'b'},
          {'__typename': 'Image', 'url': 'i.png', 'width': 1},
        ],
      },
    }).pageById(id: 'p')).page!;
    final PageFields fields = page;
    expect(fields.title, 'Home');
    final blocks = fields.blocks;
    expect((blocks.first as TextBody).body, 'b');
    expect(media(blocks.last as MediaFields), 'image i.png 1px');
  });

  test('covariant fields are narrowed per runtime type', () async {
    final titled = (await client({
      'titled': [
        {
          '__typename': 'Page',
          'title': 'Home',
          'id': 'p',
          'author': {'__typename': 'Text', 'id': 't'},
        },
        {'__typename': 'Article', 'title': null, 'author': null},
      ],
    }).titledList()).titled;

    final page = titled.first as TitledListTitled$Page;
    final String title = page.title; // Non-null on Page.
    expect(title, 'Home');
    expect(page.author?.id, 't');
    final TitledFields fields = titled.last;
    expect(fields.title, isNull);
  });
}
