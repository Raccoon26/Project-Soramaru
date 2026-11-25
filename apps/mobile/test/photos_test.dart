import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:bootstrap/community/community.dart';
import 'package:bootstrap/community/drafts.dart';
import 'package:bootstrap/membership/controller.dart';
import 'package:bootstrap/membership/gateway.dart';
import 'package:bootstrap/navigation/navigation_app.dart';
import 'package:bootstrap/navigation/sample_data.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:bootstrap/network/api_client.dart';
import 'package:bootstrap/photos/avatar.dart';
import 'package:bootstrap/photos/gallery.dart';
import 'package:bootstrap/photos/photo_jobs.dart';
import 'package:bootstrap/photos/photo_view.dart';
import 'package:bootstrap/photos/processing.dart';
import 'package:bootstrap/photos/selection.dart';
import 'package:bootstrap/ui/design.dart';
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'community_test.dart' show entry, owner;
import 'membership_test.dart' show Fixture, Vault, mailbox, samplePassword;
import 'support.dart';

const second = '06800000-0000-4000-8000-000000000013';
const frame = ValueKey('photo-preview');

img.Image syntheticPhoto(int width, int height, {int style = 0}) {
  final raster = img.Image(width: width, height: height, numChannels: 3);
  for (final p in raster) {
    final cloud = (sin(p.x / 22) * cos(p.y / 39) * 21).round();
    final contrast = p.x % 42 < 2 && p.y % 30 < 12 ? 32 : 0;
    final shade = switch (style) {
      1 => 32 + p.x * 64 ~/ width + cloud ~/ 2,
      2 => 116 + Random(p.y * width + p.x).nextInt(116) - contrast,
      _ => 160 + p.y * 55 ~/ height + cloud - contrast,
    };
    p.setRgb(
      shade.clamp(0, 255),
      (shade + 12).clamp(0, 255),
      (shade + 34).clamp(0, 255),
    );
  }
  return raster;
}

class PhotoFixture extends Fixture implements PhotoGateway {
  PhotoFixture(this.image);
  final Uint8List image;
  int requests = 0;
  @override
  Future<Uint8List> photoBytes(
    String path, {
    required String token,
    required String session,
    Uint8List? upload,
    TransferCancel? cancel,
    void Function(double)? progress,
  }) async {
    requests++;
    expect(token, 'provider-fixture');
    expect(session, 'app-fixture');
    return image;
  }

  @override
  Future<Json> api(
    String path, {
    String method = 'GET',
    String? idToken,
    String? appSession,
    Json? body,
    Map<String, String> headers = const {},
  }) async {
    if (path.startsWith('/v1/gallery')) {
      return {
        'items': [
          {
            'id': entry,
            'coverId': second,
            'title': '合成写真アルバム',
            'count': 2,
            'publishedAt': 1760000000000,
          },
        ],
      };
    }
    if (path == '/v1/media/grants') return {'items': []};
    return super.api(
      path,
      method: method,
      idToken: idToken,
      appSession: appSession,
      body: body,
      headers: headers,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real JPEG and PNG conversion strips metadata, preserves ratio and hashes variants', () async {
    final jpeg = syntheticPhoto(520, 320);
    jpeg.exif.imageIfd.orientation = 6;
    jpeg.exif.imageIfd.software = 'fixture-device';
    jpeg.exif.gpsIfd.setGpsLocation(latitude: 12.25, longitude: -45.5);
    final source = img.encodeJpg(jpeg);
    expect(latin1.decode(source), contains('Exif'));
    expect(img.decodeJpg(source)!.exif.gpsIfd.gpsLatitude, closeTo(12.25, .01));
    final result = await processPicked(XFile.fromData(source));
    expect((result.width, result.height), (320, 520));
    expect(img.decodeJpg(result.thumb)!.height, 400);
    expect(result.full.length, lessThanOrEqualTo(800000));
    expect(result.thumb.length, lessThanOrEqualTo(90000));
    expect(result.hash, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(result.thumbHash, isNot(result.hash));
    expect(latin1.decode(result.full), isNot(contains('Exif')));
    expect(img.decodeJpg(result.full)!.exif.gpsIfd.gpsLatitude, isNull);
    expect(latin1.decode(result.thumb), isNot(contains('fixture-device')));
    final png = img.Image(width: 300, height: 180, numChannels: 4);
    final avatar = await processPicked(
      XFile.fromData(img.encodePng(png)),
      avatar: true,
    );
    expect((avatar.width, avatar.height), (180, 180));
    expect(avatar.thumb, isEmpty);
    final pixel = img.decodeJpg(avatar.full)!.getPixel(50, 50);
    expect(pixel.r, greaterThan(249));
  });

  test('all eight EXIF orientations produce upright, metadata-free images', () async {
    for (var value = 1; value <= 8; value++) {
      final original = img.Image(width: 60, height: 34, numChannels: 3);
      for (final pixel in original) {
        pixel.setRgb(pixel.x < 30 ? 255 : 0, pixel.y < 17 ? 230 : 0, 0);
      }
      original.exif.imageIfd.orientation = value;
      final result = await processPicked(
        XFile.fromData(img.encodeJpg(original)),
      );
      expect((result.width, result.height), value >= 5 ? (34, 60) : (60, 34));
      final out = img.decodeJpg(result.full)!;
      final x = [1, 4, 5, 8].contains(value) ? 8 : out.width - 9;
      final y = [1, 2, 5, 6].contains(value) ? 8 : out.height - 9;
      final expected = out.getPixel(x, y);
      expect(expected.r > 190 && expected.g > 170, isTrue, reason: '$value');
      // Every transformation retains one orange corner and strips orientation.
      expect(out.exif.imageIfd.orientation, isNull);
      expect(
        [
          out.getPixel(8, 8),
          out.getPixel(out.width - 9, 8),
          out.getPixel(8, out.height - 9),
          out.getPixel(out.width - 9, out.height - 9),
        ].where((p) => p.r > 190 && p.g > 170),
        hasLength(1),
        reason: '$value ($x, $y)',
      );
    }
  });

  test(
    'damaged, unsupported, native HEIC boundary and maximum input are closed',
    () async {
      final bad = [
        Uint8List.fromList(utf8.encode('<svg/>')),
        Uint8List.fromList([255, 216, 0, 0]),
        Uint8List.fromList([
          0,
          0,
          0,
          20,
          ...ascii.encode('ftypheic'),
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]),
        Uint8List(sourceLimit + 1),
      ];
      for (final bytes in bad) {
        await expectLater(
          processPicked(XFile.fromData(bytes)),
          throwsA(isA<PhotoProblem>()),
        );
      }
    },
  );

  test(
    'representative synthetic photos record size and decoded quality',
    () async {
      final before = <int>[], full = <int>[], thumb = <int>[];
      final scores = <String>[];
      for (var style = 0; style < 3; style++) {
        final image = syntheticPhoto(960, 640, style: style);
        final bytes = img.encodePng(image);
        final result = await processPicked(XFile.fromData(bytes));
        final output = img.decodeJpg(result.full)!;
        var squareError = 0.0;
        var count = 0;
        for (var y = 0; y < image.height; y += 4) {
          for (var x = 0; x < image.width; x += 4) {
            final a = image.getPixel(x, y), b = output.getPixel(x, y);
            squareError +=
                pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2);
            count += 3;
          }
        }
        final psnr = 10 * log(255 * 255 * count / squareError) / ln10;
        expect(psnr, greaterThan(22));
        scores.add(psnr.toStringAsFixed(1));
        before.add(bytes.length);
        full.add(result.full.length);
        thumb.add(result.thumb.length);
      }
      final large = await processPicked(
        XFile.fromData(img.encodeJpg(syntheticPhoto(2100, 960))),
      );
      expect((large.width, large.height), (1920, 878));
      // ignore: avoid_print
      print(
        'DEV06 image samples PNG=$before JPG=$full thumb=$thumb PSNR=$scores',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'photo drafts restore ordered state, encrypt bytes and isolate accounts',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'soramaru-photo-tests',
      );
      final file = File('${temporary.path}/drafts.sqlite');
      final keys = Keys();
      var repo = DraftRepository(DraftDatabase(NativeDatabase(file)), keys);
      try {
        final draft = Draft.fresh();
        final first = draftId(), secondLocal = draftId();
        final converted = await processPicked(
          XFile.fromData(img.encodeJpg(syntheticPhoto(80, 55))),
        );
        final job = PhotoJob(converted, fullId: entry, thumbId: second);
        await repo.storePhoto(owner, draft.id, first, job.encode());
        await repo.storePhoto(owner, draft.id, secondLocal, job.encode());
        await repo.save(
          owner,
          Draft(
            id: draft.id,
            started: draft.started,
            updated: draft.updated,
            attachments: [secondLocal, first],
          ),
        );
        await repo.close();
        expect(
          latin1.decode(await file.readAsBytes()),
          isNot(contains(converted.hash)),
        );
        repo = DraftRepository(DraftDatabase(NativeDatabase(file)), keys);
        expect((await repo.list(owner)).single.attachments, [
          secondLocal,
          first,
        ]);
        expect(await repo.readPhoto(second, draft.id, first), isNull);
        expect(await repo.readPhoto(owner, 'other-draft', first), isNull);
        final restored = PhotoJob.decode(
          (await repo.readPhoto(owner, draft.id, first))!,
        );
        expect(restored.fullId, entry);
        expect(restored.thumbId, second);
        expect(restored.fullKey, job.fullKey);
        expect(restored.photo.full, converted.full);
        await repo.purge(owner);
        expect(await repo.list(owner), isEmpty);
        expect(await repo.readPhoto(owner, draft.id, first), isNull);
        expect(keys.values, isEmpty);
      } finally {
        await repo.close();
        await temporary.delete(recursive: true);
      }
    },
  );

  test('same processed photo is added to a draft only once', () async {
    final data = img.encodeJpg(syntheticPhoto(80, 55));
    final account = MembershipController(PhotoFixture(data), Vault());
    final repo = DraftRepository(
      DraftDatabase(NativeDatabase.memory()),
      Keys(),
    );
    final api = Community(account, repo);
    try {
      await account.signIn(mailbox, samplePassword);
      final jobs = PhotoJobs(api);
      final draft = Draft.fresh();
      final first = await jobs.add(draft.id, XFile.fromData(data), []);
      expect(first, isNotNull);
      expect(await jobs.add(draft.id, XFile.fromData(data), [first!]), isNull);
    } finally {
      api.dispose();
      account.dispose();
      await repo.close();
    }
  });

  testWidgets('picker caps existing attachments, reorders and confirms removal', (
    tester,
  ) async {
    configureView(tester, const Size(430, 940));
    final account = MembershipController(
      PhotoFixture(img.encodeJpg(syntheticPhoto(40, 28))),
      Vault(),
    );
    final repo = DraftRepository(
      DraftDatabase(NativeDatabase.memory()),
      Keys(),
    );
    final api = Community(account, repo);
    await account.signIn(mailbox, samplePassword);
    final paths = List.generate(
      10,
      (index) =>
          '06800000-0000-4000-8000-${(20 + index).toString().padLeft(12, '0')}',
    );
    List<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<List<String>>(
                  MaterialPageRoute(
                    builder: (_) => PhotoSelection(
                      api,
                      SelectionRequest('draft', paths, entry),
                    ),
                  ),
                );
              },
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.textContaining('10/10'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '写真を選択'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('次に移動').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('写真を外す').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('完了'),
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('完了'));
    await tester.pumpAndSettle();
    expect(result, [paths[0], ...paths.skip(2)]);
    await tester.pumpWidget(const SizedBox.shrink());
    api.dispose();
    account.dispose();
    await tester.runAsync(repo.close);
  });

  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('photo layout ${width.toInt()}dp at $scale scale', (
        tester,
      ) async {
        configureView(tester, Size(width, 840), scale: scale);
        final gateway = PhotoFixture(img.encodeJpg(syntheticPhoto(180, 120)));
        final account = MembershipController(gateway, Vault());
        final drafts = DraftRepository(
          DraftDatabase(NativeDatabase.memory()),
          Keys(),
        );
        final api = Community(account, drafts);
        await account.signIn(mailbox, samplePassword);
        final collect =
            const bool.fromEnvironment('DEV06_PREVIEW') &&
            width == 390 &&
            scale == 1;
        if (collect) {
          await tester.runAsync(() async {
            final japanese = FontLoader('DEV06 JP')
              ..addFont(
                File('../../.local/downloads/NotoSansJP.ttf')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              );
            await japanese.load();
            final icons = FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
            await icons.load();
          });
        }
        Future<void> show(Widget child) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: soramaruTheme(fontFamily: collect ? 'DEV06 JP' : null),
              home: RepaintBoundary(key: frame, child: child),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> capture(String name) async {
          if (!collect) return;
          final images = find.byType(RawImage);
          for (var attempt = 0; attempt < 20; attempt++) {
            if (tester
                .widgetList<RawImage>(images)
                .every((widget) => widget.image != null)) {
              break;
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            await tester.pump();
          }
          expect(
            tester.widgetList<RawImage>(images).map((widget) => widget.image),
            isNot(contains(null)),
          );
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(frame),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1.5);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory('../../.local/dev-06-preview');
            await directory.create(recursive: true);
            await File('${directory.path}/$name.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        final ids = [entry, second];
        await show(
          PhotoSelection(api, SelectionRequest('test-draft', ids, entry)),
        );
        expect(find.textContaining('2/10'), findsOneWidget);
        expect(find.text('カメラで撮影'), findsOneWidget);
        await capture('01-selection');

        await show(
          PhotoViewer(
            api,
            ids.map((id) => PhotoPointer('post', entry, id)).toList(),
          ),
        );
        expect(find.text('1 / 2'), findsOneWidget);
        expect(find.bySemanticsLabel('写真 2'), findsOneWidget);
        await capture('02-viewer');
        await tester.tap(find.bySemanticsLabel('写真 2'));
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        final pane = find.byType(InteractiveViewer);
        final zoom = tester
            .widget<InteractiveViewer>(pane)
            .transformationController!;
        zoom.value = Matrix4.diagonal3Values(2, 2, 1);
        await tester.pump();
        expect(
          tester.widget<PageView>(find.byType(PageView)).physics,
          isA<NeverScrollableScrollPhysics>(),
        );
        zoom.value = Matrix4.identity();
        await tester.pump();

        final nav = NavigationController(
          session: () => const DemoSession(),
          resources: const SampleResources(),
          now: DateTime.now,
          generation: 0,
          community: api,
        );
        await show(Scaffold(body: GalleryPage(nav)));
        expect(find.text('合成写真アルバム'), findsOneWidget);
        expect(find.text('公式　2枚'), findsOneWidget);
        await capture('03-gallery');
        String? changed = second;
        await show(
          Scaffold(
            body: AvatarPicker(
              api,
              entry,
              onChanged: (v) => changed = v,
              onBusy: (_) {},
            ),
          ),
        );
        await capture('04-avatar');
        await tester.tap(find.text('画像を削除'));
        await tester.pumpAndSettle();
        expect(changed, isNull);
        expect(gateway.requests, greaterThan(1));
        await tester.pumpWidget(const SizedBox.shrink());
        nav.dispose();
        account.dispose();
        await tester.runAsync(drafts.close);
      });
    }
  }
}
