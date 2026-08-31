// /opt/legend-connect/config/web/custom-config.js
// Образ jitsi/web дописывает этот файл в конец сгенерированного config.js — правки переживают
// пересоздание контейнера, в отличие от прямого редактирования config.js.
//
// ⚠️ ФАЙЛ ПУБЛИЧНЫЙ: он отдаётся браузеру любого участника встречи, включая клиентов.
// Никаких внутренних подробностей — причины правок, разборы инцидентов и имена сотрудников
// держим в памяти проекта и в истории git, здесь только короткое «что делает».

// Гость по ссылке в режиме «через модератора» ждёт в комнате ожидания и стучится автоматически,
// без отдельного нажатия — иначе запрос до ведущего не доходит.
config.lobby = Object.assign({}, config.lobby, { autoKnock: true });

// Кодек: VP9 первым. AV1 кодируется программно и на ноутбуках сажает батарею и качество картинки.
config.videoQuality = Object.assign({}, config.videoQuality, {
  codecPreferenceOrder: ['H264', 'VP9', 'VP8', 'AV1'],
  maxFullResolutionParticipants: 4,
});

// Ключ отсутствует в этой сборке — снимаем, чтобы не выглядел работающей настройкой.
if (config.videoQuality) { delete config.videoQuality.enableAdaptiveMode; }

// Состав кнопок панели. Убраны встроенные запись и трансляция (у нас своя запись) и «встроить
// встречу» — сотрудникам не нужна. Список соответствует сборке.
config.toolbarButtons = [
  "camera", "chat", "closedcaptions", "custom-panel", "desktop", "download", "etherpad", "feedback",
  "filesharing", "fullscreen", "hangup", "help", "highlight", "invite", "linktosalesforce", "microphone",
  "mute-everyone", "mute-video-everyone", "participants-pane", "polls", "profile", "raisehand", "security",
  "select-background", "settings", "shareaudio", "noisesuppression", "sharedvideo", "shortcuts", "stats",
  "tileview", "toggle-camera", "videoquality", "whiteboard"
];

// Звонок вдвоём идёт напрямую между участниками (p2p), и у него СВОЙ порядок кодеков — в шаблоне
// там тоже AV1 первым. Из-за этого демонстрация экрана в разговоре один на один кодировалась в AV1,
// и собеседник с устройством без его поддержки видел камеру, но не видел показ экрана.
// Держим тот же порядок, что и для групповых встреч.
config.p2p = Object.assign({}, config.p2p, {
  codecPreferenceOrder: ['H264', 'VP9', 'VP8', 'AV1'],
  mobileCodecPreferenceOrder: ['H264', 'VP8', 'VP9', 'AV1'],
});

// Почему H264 первым: у Apple аппаратно кодируется ТОЛЬКО H264/HEVC. VP8, VP9 и AV1 на маке жмутся
// процессором — отсюда сажающаяся за минуты батарея и падение картинки до 180p, когда процессор не
// вытягивает. H264 отдаёт кодирование видеочипу: ноутбук перестаёт греться, а качество держится.
// AV1 оставлен последним — если у кого-то появится железо с его аппаратной поддержкой, он его получит.

// Битрейты для H264. В шаблоне config.videoQuality.h264 — ПУСТОЙ объект, поэтому после перехода на
// H264 и камера, и особенно демонстрация экрана уходили на минимальных дефолтах: показывающий
// отдавал 97 Kbps в 320x180 при потерях всего 2% — то есть картинка была размыта ещё до сети.
// ssHigh — это отдельный потолок именно для показа экрана, где важна читаемость текста.
config.videoQuality = Object.assign({}, config.videoQuality, {
  h264: {
    maxBitratesVideo: {
      low: 400000,
      standard: 1200000,
      high: 2500000,
      fullHd: 4000000,
      ultraHd: 6000000,
      ssHigh: 4000000,
    },
  },
});

// Демонстрация экрана: не даём Jitsi ронять частоту до слайд-шоу, но и не гонимся за 30 кадрами —
// для таблиц и документов важнее чёткость, чем плавность.
config.desktopSharingFrameRate = { min: 5, max: 15 };
