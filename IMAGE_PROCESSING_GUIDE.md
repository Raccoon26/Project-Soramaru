# 이미지 처리

| 항목 | 제한 |
|---|---|
| 입력 | JPEG·정적 PNG 20 MiB, 가로·세로 각각 10,240px, JPEG 32MP·PNG 16MP. 손상된 형식과 APNG 등 동적 이미지는 거부한다. |
| HEIC/HEIF | 매직과 브랜드를 확인해 Android API 28+ ImageDecoder, iOS ImageIO의 백그라운드 변환을 시도한다. 읽을 수 없는 경우 일본어 오류를 표시한다. Android API 24~27은 플랫폼 디코더 지원이 필요하다. |
| 게시 사진 | 긴 변 1,920px, 4:2:0 JPEG 품질 86→81→75→68, 최대 800,000B. 비율을 유지하고 작은 원본은 확대하지 않는다. |
| 썸네일 | 긴 변 400px, 품질 78→73→65, 최대 90,000B. |
| 프로필 | 최대 512px 정방형 중앙 크롭, 최대 150,000B. |
| 공식 갤러리 | 서버 승인 상한 2,048px 및 800,000B. 등록 도구와 운영자 UI는 후속 단계다. |

선택 URI는 스트림으로 제한해 읽고, JPEG는 일부 크기에서 디코더의 축소 기능을 이용한다. EXIF 방향을 픽셀에 반영하고 새 RGB 래스터에 흰색 바탕으로 합성한 뒤 JPEG로 저장한다. HEIC 네이티브 변환은 sRGB를 지정한다. 메타데이터와 원본 컬러 프로필은 출력으로 복사하지 않는다. 입력 픽셀에 이미 포함된 주소·사람·번호판은 남는다. 실제 원본에 쓰기 작업을 수행하지 않는다.

합성 밝음·어두움·고주파 세부 960×640px 3종을 대상으로 PNG 평균 525,862B, 게시 JPEG 126,923B, 썸네일 15,609B를 측정했다. 동일 위치 RGB PSNR은 47.7·51.0·34.7dB이었다. 표준 테스트는 2,100px 입력 축소와 EXIF 방향 1~8을 포함한다. 실제 아이폰의 HEIC 방향과 광색역 사진의 색상, 일본어 OCR 가독성·발열·배터리는 기기에서 비교한다.

서버는 JPEG 단일 스캔 8비트 baseline, 허용 세그먼트와 정상 EOI, 크기·픽셀·해시를 확인한 뒤 JPEG 디코딩을 수행한다. 제한을 초과하거나 검사할 수 없는 자료는 승인되지 않는다. Worker Free CPU에서는 최악의 정상 이미지까지 검증한 뒤 운영 승인을 받는다. [iOS 시스템 선택기](https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios) · [Android 사진 선택기](https://developer.android.com/training/data-storage/shared/photopicker) · [Flutter image_picker](https://pub.dev/packages/image_picker)
