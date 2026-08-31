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
  codecPreferenceOrder: ['VP9', 'VP8', 'H264', 'AV1'],
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
