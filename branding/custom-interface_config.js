// Legend Connect — брендинг Jitsi (логотип/имя, скрыт jitsi-промо).
// УСТАНОВКА на сервере: положить в /opt/legend-connect/config/web/custom-interface_config.js
// Entrypoint web-контейнера дописывает этот файл в конец /config/interface_config.js при КАЖДОМ старте
// (см. /etc/cont-init.d/10-config: `cat /config/custom-interface_config.js >> ...`) → переживает рестарты.
// Применить: docker compose restart web
interfaceConfig.APP_NAME = "Legend Connect";
interfaceConfig.NATIVE_APP_NAME = "Legend Connect";
interfaceConfig.PROVIDER_NAME = "Legend";
interfaceConfig.SHOW_JITSI_WATERMARK = true;                 // watermark показываем — но НАШ логотип
interfaceConfig.SHOW_WATERMARK_FOR_GUESTS = true;
interfaceConfig.JITSI_WATERMARK_LINK = "https://op.1leg.ru";
interfaceConfig.DEFAULT_LOGO_URL = "https://op.1leg.ru/legend-connect-logo.png";
interfaceConfig.DEFAULT_WELCOME_PAGE_LOGO_URL = "https://op.1leg.ru/legend-connect-logo.png";
interfaceConfig.MOBILE_APP_PROMO = false;
interfaceConfig.HIDE_DEEP_LINKING_LOGO = true;
interfaceConfig.SHOW_BRAND_WATERMARK = false;
