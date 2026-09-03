#!/usr/bin/env python3
"""Emit Pelmet/Resources/Localizable.xcstrings from the table below.

Source of truth for translations. Edit a string here, re-run, commit both.
English keys must match the literals in code byte-for-byte (dashes, ellipses,
newlines). Interpolations use `%@`. Xcode's String Catalog editor can still
open the output; hand-edits there get overwritten by this script, so keep
edits here.
"""

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Pelmet" / "Resources" / "Localizable.xcstrings"

# key -> {lang: translation}
T = {
    # ── Settings shell ──────────────────────────────────────────────
    "General": dict(de="Allgemein", fr="Général", es="General", it="Generali", pt="Geral", ja="一般", zh="通用", ko="일반", ru="Основные"),
    "Menu Bar": dict(de="Menüleiste", fr="Barre des menus", es="Barra de menús", it="Barra dei menu", pt="Barra de menus", ja="メニューバー", zh="菜单栏", ko="메뉴 막대", ru="Строка меню"),
    "Displays": dict(de="Displays", fr="Écrans", es="Pantallas", it="Schermi", pt="Telas", ja="ディスプレイ", zh="显示器", ko="디스플레이", ru="Мониторы"),
    "About": dict(de="Über", fr="À propos", es="Acerca de", it="Informazioni", pt="Sobre", ja="情報", zh="关于", ko="정보", ru="О программе"),
    "Pelmet Settings": dict(de="Pelmet-Einstellungen", fr="Réglages de Pelmet", es="Ajustes de Pelmet", it="Impostazioni di Pelmet", pt="Ajustes do Pelmet", ja="Pelmet設定", zh="Pelmet 设置", ko="Pelmet 설정", ru="Настройки Pelmet"),

    # ── General pane ────────────────────────────────────────────────
    "Launch at login": dict(de="Bei der Anmeldung öffnen", fr="Ouvrir à l’ouverture de session", es="Abrir al iniciar sesión", it="Apri al login", pt="Abrir ao iniciar sessão", ja="ログイン時に起動", zh="登录时启动", ko="로그인 시 열기", ru="Открывать при входе"),
    "Show Pelmet icon in the menu bar": dict(de="Pelmet-Symbol in der Menüleiste anzeigen", fr="Afficher l’icône Pelmet dans la barre des menus", es="Mostrar el icono de Pelmet en la barra de menús", it="Mostra l’icona di Pelmet nella barra dei menu", pt="Mostrar o ícone do Pelmet na barra de menus", ja="メニューバーにPelmetアイコンを表示", zh="在菜单栏中显示 Pelmet 图标", ko="메뉴 막대에 Pelmet 아이콘 표시", ru="Показывать значок Pelmet в строке меню"),
    "Without it: reopen Pelmet from Spotlight, or right-click a separator or empty menu bar spot.": dict(
        de="Ohne Symbol: Pelmet erneut über Spotlight öffnen oder mit der rechten Maustaste auf einen Trenner oder eine freie Stelle der Menüleiste klicken.",
        fr="Sans elle : rouvrez Pelmet depuis Spotlight, ou faites un clic droit sur un séparateur ou une zone vide de la barre des menus.",
        es="Sin él: vuelve a abrir Pelmet desde Spotlight, o haz clic derecho en un separador o en un espacio vacío de la barra de menús.",
        it="Senza icona: riapri Pelmet da Spotlight, oppure fai clic destro su un separatore o su uno spazio vuoto della barra dei menu.",
        pt="Sem ele: reabra o Pelmet pelo Spotlight, ou clique com o botão direito em um separador ou em um espaço vazio da barra de menus.",
        ja="非表示の場合：SpotlightからPelmetを再度開くか、区切りまたはメニューバーの空いている場所を右クリックしてください。",
        zh="隐藏后：可通过 Spotlight 重新打开 Pelmet，或右键点击分隔符或菜单栏的空白处。",
        ko="숨기면: Spotlight에서 Pelmet을 다시 열거나, 구분선 또는 메뉴 막대의 빈 곳을 오른쪽 클릭하세요.",
        ru="Без значка: откройте Pelmet через Spotlight или нажмите правой кнопкой на разделитель или пустое место строки меню."),
    "Language": dict(de="Sprache", fr="Langue", es="Idioma", it="Lingua", pt="Idioma", ja="言語", zh="语言", ko="언어", ru="Язык"),
    "Relaunches Pelmet to apply.": dict(de="Pelmet wird zum Übernehmen neu gestartet.", fr="Pelmet redémarre pour appliquer.", es="Pelmet se reinicia para aplicarlo.", it="Pelmet si riavvia per applicare.", pt="O Pelmet reinicia para aplicar.", ja="適用するにはPelmetが再起動します。", zh="Pelmet 将重新启动以应用。", ko="적용하려면 Pelmet이 다시 실행됩니다.", ru="Pelmet перезапустится, чтобы применить."),
    "System language": dict(de="Systemsprache", fr="Langue du système", es="Idioma del sistema", it="Lingua di sistema", pt="Idioma do sistema", ja="システムの言語", zh="系统语言", ko="시스템 언어", ru="Язык системы"),
    "Relaunch Pelmet to change its language?": dict(de="Pelmet neu starten, um die Sprache zu ändern?", fr="Redémarrer Pelmet pour changer de langue ?", es="¿Reiniciar Pelmet para cambiar el idioma?", it="Riavviare Pelmet per cambiare lingua?", pt="Reiniciar o Pelmet para mudar o idioma?", ja="言語を変更するためにPelmetを再起動しますか？", zh="要重新启动 Pelmet 以更改语言吗？", ko="언어를 변경하기 위해 Pelmet을 다시 실행할까요?", ru="Перезапустить Pelmet, чтобы сменить язык?"),
    "The new language applies the next time Pelmet opens. Your menu bar layout is kept.": dict(de="Die neue Sprache gilt ab dem nächsten Start von Pelmet. Dein Menüleisten-Layout bleibt erhalten.", fr="La nouvelle langue s’applique à la prochaine ouverture de Pelmet. La disposition de votre barre des menus est conservée.", es="El nuevo idioma se aplica la próxima vez que se abra Pelmet. La disposición de tu barra de menús se conserva.", it="La nuova lingua si applica alla prossima apertura di Pelmet. La disposizione della barra dei menu viene conservata.", pt="O novo idioma vale na próxima vez que o Pelmet abrir. A disposição da sua barra de menus é mantida.", ja="新しい言語は次回Pelmetを開いたときに適用されます。メニューバーの配置はそのまま保持されます。", zh="新语言将在下次打开 Pelmet 时生效。菜单栏布局会保留。", ko="새 언어는 다음에 Pelmet을 열 때 적용됩니다. 메뉴 막대 배치는 그대로 유지됩니다.", ru="Новый язык применится при следующем запуске Pelmet. Раскладка строки меню сохранится."),
    "Relaunch Now": dict(de="Jetzt neu starten", fr="Redémarrer maintenant", es="Reiniciar ahora", it="Riavvia ora", pt="Reiniciar agora", ja="今すぐ再起動", zh="立即重新启动", ko="지금 다시 실행", ru="Перезапустить сейчас"),
    "Later": dict(de="Später", fr="Plus tard", es="Más tarde", it="Più tardi", pt="Mais tarde", ja="あとで", zh="稍后", ko="나중에", ru="Позже"),
    "Reveal": dict(de="Einblenden", fr="Affichage", es="Mostrar", it="Mostra", pt="Revelar", ja="表示", zh="显示", ko="표시", ru="Показ"),
    "Reveal on hover": dict(de="Beim Überfahren einblenden", fr="Afficher au survol", es="Mostrar al pasar el cursor", it="Mostra al passaggio del cursore", pt="Revelar ao passar o cursor", ja="ホバーで表示", zh="悬停时显示", ko="마우스를 올리면 표시", ru="Показывать при наведении"),
    "Hover delay": dict(de="Verzögerung", fr="Délai de survol", es="Retardo", it="Ritardo", pt="Atraso", ja="ホバーの遅延", zh="悬停延迟", ko="지연 시간", ru="Задержка"),
    "Reveal on click in empty menu bar area": dict(de="Bei Klick auf freie Menüleistenfläche einblenden", fr="Afficher au clic dans une zone vide de la barre des menus", es="Mostrar al hacer clic en un área vacía de la barra de menús", it="Mostra al clic su un’area vuota della barra dei menu", pt="Revelar ao clicar em uma área vazia da barra de menus", ja="メニューバーの空いている場所をクリックで表示", zh="点击菜单栏空白处时显示", ko="메뉴 막대 빈 곳을 클릭하면 표시", ru="Показывать при щелчке по пустой области строки меню"),
    "Double-click reveals always-hidden too": dict(de="Doppelklick blendet auch „Immer ausgeblendet“ ein", fr="Le double-clic affiche aussi les éléments toujours masqués", es="El doble clic también muestra los siempre ocultos", it="Il doppio clic mostra anche i sempre nascosti", pt="Clique duplo revela também os sempre ocultos", ja="ダブルクリックで「常に非表示」も表示", zh="双击同时显示“始终隐藏”的图标", ko="더블 클릭 시 항상 숨김 항목도 표시", ru="Двойной щелчок показывает и всегда скрытые"),
    "Reveal animation": dict(de="Animation", fr="Animation", es="Animación", it="Animazione", pt="Animação", ja="表示アニメーション", zh="显示动画", ko="표시 애니메이션", ru="Анимация показа"),
    "Instant": dict(de="Sofort", fr="Instantané", es="Instantánea", it="Istantanea", pt="Instantânea", ja="即時", zh="即时", ko="즉시", ru="Мгновенно"),
    "Smooth": dict(de="Sanft", fr="Fluide", es="Suave", it="Fluida", pt="Suave", ja="スムーズ", zh="平滑", ko="부드럽게", ru="Плавно"),
    "Fade": dict(de="Überblenden", fr="Fondu", es="Fundido", it="Dissolvenza", pt="Esmaecer", ja="フェード", zh="淡入淡出", ko="페이드", ru="Затухание"),
    "Auto-rehide": dict(de="Automatisch ausblenden", fr="Masquage automatique", es="Ocultar automáticamente", it="Nascondi automaticamente", pt="Ocultar automaticamente", ja="自動的に隠す", zh="自动重新隐藏", ko="자동 숨김", ru="Автоскрытие"),
    "Automatically rehide": dict(de="Automatisch wieder ausblenden", fr="Masquer à nouveau automatiquement", es="Volver a ocultar automáticamente", it="Nascondi di nuovo automaticamente", pt="Ocultar novamente de forma automática", ja="自動的に再び隠す", zh="自动重新隐藏", ko="자동으로 다시 숨김", ru="Скрывать автоматически"),
    "After": dict(de="Nach", fr="Après", es="Tras", it="Dopo", pt="Após", ja="経過後", zh="延迟", ko="대기 시간", ru="Через"),
    "Rehide when clicking elsewhere": dict(de="Bei Klick an anderer Stelle ausblenden", fr="Masquer en cliquant ailleurs", es="Ocultar al hacer clic en otro sitio", it="Nascondi quando fai clic altrove", pt="Ocultar ao clicar em outro lugar", ja="他の場所をクリックしたら隠す", zh="点击其他位置时隐藏", ko="다른 곳을 클릭하면 숨김", ru="Скрывать при щелчке в другом месте"),
    "System extras": dict(de="System-Extras", fr="Extras système", es="Extras del sistema", it="Extra di sistema", pt="Extras do sistema", ja="システムの追加項目", zh="系统附加项", ko="시스템 추가 항목", ru="Системные элементы"),
    "Now Playing, camera controls, AirDrop, Focus": dict(de="Jetzt läuft, Kamerasteuerung, AirDrop, Fokus", fr="Lecture en cours, commandes de caméra, AirDrop, Concentration", es="Ahora suena, controles de cámara, AirDrop, Modos de concentración", it="In riproduzione, controlli fotocamera, AirDrop, Full immersion", pt="Tocando agora, controles de câmera, AirDrop, Foco", ja="再生中、カメラコントロール、AirDrop、集中モード", zh="现在播放、相机控制、隔空投送、专注模式", ko="지금 재생 중, 카메라 제어, AirDrop, 집중 모드", ru="Сейчас играет, управление камерой, AirDrop, Фокусирование"),
    "Notification Center": dict(de="Mitteilungszentrale", fr="Centre de notifications", es="Centro de notificaciones", it="Centro Notifiche", pt="Central de Notificações", ja="通知センター", zh="通知中心", ko="알림 센터", ru="Центр уведомлений"),
    "Clicking the clock opens Notification Center": dict(de="Klick auf die Uhr öffnet die Mitteilungszentrale", fr="Un clic sur l’horloge ouvre le centre de notifications", es="Hacer clic en el reloj abre el centro de notificaciones", it="Il clic sull’orologio apre Centro Notifiche", pt="Clicar no relógio abre a Central de Notificações", ja="時計をクリックで通知センターを開く", zh="点击时钟打开通知中心", ko="시계를 클릭하면 알림 센터 열기", ru="Щелчок по часам открывает Центр уведомлений"),
    "macOS blocks that click while any icons are hidden. Pelmet shows everything for a blink so it gets through.": dict(
        de="macOS blockiert diesen Klick, solange irgendein Symbol verborgen ist. Pelmet zeigt alles für einen Augenblick, damit er durchkommt.",
        fr="macOS bloque ce clic tant qu’une icône est masquée. Pelmet affiche tout l’espace d’un instant pour le laisser passer.",
        es="macOS bloquea ese clic mientras haya algún icono oculto. Pelmet muestra todo por un instante para que llegue.",
        it="macOS blocca quel clic finché un’icona è nascosta. Pelmet mostra tutto per un istante per farlo passare.",
        pt="O macOS bloqueia esse clique enquanto algum ícone estiver oculto. O Pelmet mostra tudo por um instante para ele passar.",
        ja="アイコンが1つでも隠れているとmacOSはこのクリックをブロックします。Pelmetは一瞬すべてを表示してクリックを通します。",
        zh="只要有任何图标被隐藏，macOS 就会拦截这次点击。Pelmet 会短暂显示全部图标，让点击生效。",
        ko="아이콘이 하나라도 숨겨져 있으면 macOS가 이 클릭을 막습니다. Pelmet이 잠깐 모두 표시해 클릭이 전달되게 합니다.",
        ru="macOS блокирует этот щелчок, пока скрыт хотя бы один значок. Pelmet на миг показывает всё, чтобы он прошёл."),
    "macOS hides these whenever any icons are concealed — they can only appear while the whole bar is revealed.": dict(
        de="macOS blendet diese aus, sobald irgendein Symbol verborgen ist – sie erscheinen nur, während die gesamte Leiste eingeblendet ist.",
        fr="macOS les masque dès qu’une icône est cachée : ils n’apparaissent que lorsque toute la barre est affichée.",
        es="macOS los oculta siempre que haya algún icono escondido: solo aparecen mientras toda la barra está visible.",
        it="macOS li nasconde ogni volta che un’icona è celata: compaiono solo mentre l’intera barra è visibile.",
        pt="O macOS os oculta sempre que algum ícone está escondido: só aparecem enquanto a barra inteira está visível.",
        ja="macOSはアイコンが1つでも隠れているとこれらを非表示にします。バー全体が表示されている間のみ表示されます。",
        zh="只要有任何图标被隐藏，macOS 就会隐藏这些项目，它们仅在整个菜单栏显示时才会出现。",
        ko="아이콘이 하나라도 숨겨져 있으면 macOS가 이 항목들을 숨깁니다. 막대 전체가 표시될 때만 나타납니다.",
        ru="macOS скрывает их, как только скрыт хотя бы один значок: они видны только при полностью показанной строке меню."),
    "Always hidden": dict(de="Immer ausgeblendet", fr="Toujours masqués", es="Siempre ocultos", it="Sempre nascosti", pt="Sempre ocultos", ja="常に非表示", zh="始终隐藏", ko="항상 숨김", ru="Всегда скрыты"),
    "Show while revealed": dict(de="Beim Einblenden anzeigen", fr="Afficher lorsque la barre est déployée", es="Mostrar mientras esté visible", it="Mostra quando la barra è visibile", pt="Mostrar enquanto revelado", ja="表示中は見せる", zh="显示时可见", ko="표시 중일 때 보이기", ru="Показывать при развёрнутой строке"),
    "Pelmet stays a click away": dict(de="Pelmet bleibt einen Klick entfernt", fr="Pelmet reste à portée de clic", es="Pelmet sigue a un clic", it="Pelmet resta a un clic di distanza", pt="O Pelmet continua a um clique", ja="Pelmetはいつでもすぐに開けます", zh="Pelmet 始终触手可及", ko="Pelmet은 언제나 한 번의 클릭으로 열 수 있습니다", ru="Pelmet всегда в одном клике"),
    "You can always open Pelmet Settings by:\n\n•  Opening Pelmet again from Spotlight or Finder\n•  Right-clicking any Pelmet separator in the menu bar\n•  Right-clicking an empty spot in the menu bar": dict(
        de="Die Pelmet-Einstellungen sind jederzeit erreichbar:\n\n•  Pelmet erneut über Spotlight oder den Finder öffnen\n•  Rechtsklick auf einen Pelmet-Trenner in der Menüleiste\n•  Rechtsklick auf eine freie Stelle der Menüleiste",
        fr="Vous pouvez toujours ouvrir les réglages de Pelmet :\n\n•  En rouvrant Pelmet depuis Spotlight ou le Finder\n•  Par un clic droit sur un séparateur Pelmet dans la barre des menus\n•  Par un clic droit sur une zone vide de la barre des menus",
        es="Siempre puedes abrir los ajustes de Pelmet:\n\n•  Abriendo Pelmet de nuevo desde Spotlight o el Finder\n•  Haciendo clic derecho en cualquier separador de Pelmet en la barra de menús\n•  Haciendo clic derecho en un espacio vacío de la barra de menús",
        it="Puoi sempre aprire le impostazioni di Pelmet:\n\n•  Riaprendo Pelmet da Spotlight o dal Finder\n•  Con un clic destro su un separatore Pelmet nella barra dei menu\n•  Con un clic destro su uno spazio vuoto della barra dei menu",
        pt="Você sempre pode abrir os ajustes do Pelmet:\n\n•  Abrindo o Pelmet novamente pelo Spotlight ou pelo Finder\n•  Clicando com o botão direito em qualquer separador do Pelmet na barra de menus\n•  Clicando com o botão direito em um espaço vazio da barra de menus",
        ja="Pelmet設定は次の方法でいつでも開けます：\n\n•  SpotlightまたはFinderからPelmetを再度開く\n•  メニューバーのPelmet区切りを右クリック\n•  メニューバーの空いている場所を右クリック",
        zh="你随时可以通过以下方式打开 Pelmet 设置：\n\n•  在 Spotlight 或访达中再次打开 Pelmet\n•  右键点击菜单栏中的任意 Pelmet 分隔符\n•  右键点击菜单栏的空白处",
        ko="Pelmet 설정은 언제든지 다음 방법으로 열 수 있습니다:\n\n•  Spotlight 또는 Finder에서 Pelmet을 다시 열기\n•  메뉴 막대의 Pelmet 구분선을 오른쪽 클릭\n•  메뉴 막대의 빈 곳을 오른쪽 클릭",
        ru="Настройки Pelmet всегда можно открыть:\n\n•  Снова открыв Pelmet через Spotlight или Finder\n•  Правым щелчком по любому разделителю Pelmet в строке меню\n•  Правым щелчком по пустому месту строки меню"),

    # ── Displays pane ───────────────────────────────────────────────
    "Notch": dict(de="Notch", fr="Encoche", es="Notch", it="Notch", pt="Notch", ja="ノッチ", zh="刘海", ko="노치", ru="Вырез"),
    "Collapse": dict(de="Einklappen", fr="Replier", es="Contraer", it="Comprimi", pt="Recolher", ja="折りたたむ", zh="折叠", ko="접기", ru="Сворачивать"),
    "Expanded": dict(de="Ausgeklappt", fr="Déployée", es="Expandida", it="Espansa", pt="Expandida", ja="展開", zh="展开", ko="펼침", ru="Развёрнуто"),

    # ── About pane ──────────────────────────────────────────────────
    "Version %@ (%@)": dict(de="Version %@ (%@)", fr="Version %@ (%@)", es="Versión %@ (%@)", it="Versione %@ (%@)", pt="Versão %@ (%@)", ja="バージョン %@ (%@)", zh="版本 %@ (%@)", ko="버전 %@ (%@)", ru="Версия %@ (%@)"),
    "Replay the intro": dict(de="Einführung erneut ansehen", fr="Revoir l’introduction", es="Repetir la introducción", it="Rivedi l’introduzione", pt="Rever a introdução", ja="イントロをもう一度見る", zh="重看介绍", ko="소개 다시 보기", ru="Показать вступление снова"),
    "Update to %@": dict(de="Auf %@ aktualisieren", fr="Mettre à jour vers %@", es="Actualizar a %@", it="Aggiorna a %@", pt="Atualizar para %@", ja="%@ にアップデート", zh="更新到 %@", ko="%@(으)로 업데이트", ru="Обновить до %@"),
    "Checking for updates…": dict(de="Suche nach Updates …", fr="Recherche de mises à jour…", es="Buscando actualizaciones…", it="Ricerca aggiornamenti…", pt="Buscando atualizações…", ja="アップデートを確認中…", zh="正在检查更新…", ko="업데이트 확인 중…", ru="Проверка обновлений…"),
    "You're on the latest version": dict(de="Du hast die neueste Version", fr="Vous avez la dernière version", es="Tienes la última versión", it="Hai l’ultima versione", pt="Você está na versão mais recente", ja="最新バージョンです", zh="已是最新版本", ko="최신 버전입니다", ru="У вас последняя версия"),
    "Check for updates": dict(de="Nach Updates suchen", fr="Rechercher des mises à jour", es="Buscar actualizaciones", it="Cerca aggiornamenti", pt="Buscar atualizações", ja="アップデートを確認", zh="检查更新", ko="업데이트 확인", ru="Проверить обновления"),

    # ── Menu Bar tab (editor) ───────────────────────────────────────
    "Hiding is unavailable on this macOS build — reordering still works.": dict(de="Ausblenden ist auf diesem macOS-Build nicht verfügbar – Umsortieren funktioniert weiterhin.", fr="Le masquage n’est pas disponible sur cette version de macOS : le réordonnancement fonctionne toujours.", es="Ocultar no está disponible en esta versión de macOS: reordenar sigue funcionando.", it="Nascondere non è disponibile in questa build di macOS: riordinare funziona ancora.", pt="Ocultar não está disponível nesta versão do macOS: reordenar continua funcionando.", ja="このmacOSビルドでは非表示は使えません。並べ替えは引き続き可能です。", zh="此 macOS 版本不支持隐藏，但仍可重新排序。", ko="이 macOS 빌드에서는 숨기기를 사용할 수 없습니다. 순서 변경은 계속 가능합니다.", ru="Скрытие недоступно в этой сборке macOS: переупорядочивание по-прежнему работает."),
    "Tidying…": dict(de="Wird aufgeräumt …", fr="Rangement…", es="Ordenando…", it="Riordino…", pt="Organizando…", ja="整理中…", zh="正在整理…", ko="정리 중…", ru="Упорядочивание…"),
    "Tidy bar order": dict(de="Leiste aufräumen", fr="Ranger la barre", es="Ordenar la barra", it="Riordina la barra", pt="Organizar a barra", ja="バーの並びを整理", zh="整理菜单栏顺序", ko="막대 순서 정리", ru="Упорядочить строку"),
    "Physically arranges the bar to match the sections — icons that sit out of place slide their neighbors on every reveal.": dict(de="Ordnet die Leiste physisch nach den Bereichen – falsch platzierte Symbole verschieben bei jedem Einblenden ihre Nachbarn.", fr="Réorganise physiquement la barre selon les sections : les icônes mal placées décalent leurs voisines à chaque affichage.", es="Reordena físicamente la barra según las secciones: los iconos fuera de sitio desplazan a sus vecinos en cada aparición.", it="Riordina fisicamente la barra secondo le sezioni: le icone fuori posto spostano le vicine a ogni comparsa.", pt="Reorganiza fisicamente a barra conforme as seções: ícones fora do lugar deslocam os vizinhos a cada revelação.", ja="セクションに合わせてバーを実際に並べ替えます。位置がずれたアイコンは表示のたびに隣のアイコンを動かします。", zh="按分区实际重排菜单栏，位置不当的图标每次显示时都会推挤相邻图标。", ko="섹션에 맞게 막대를 실제로 재배치합니다. 위치가 어긋난 아이콘은 표시될 때마다 이웃을 밀어냅니다.", ru="Физически выстраивает строку по секциям: значки не на своём месте сдвигают соседей при каждом показе."),
    "Visible": dict(de="Sichtbar", fr="Visibles", es="Visibles", it="Visibili", pt="Visíveis", ja="表示", zh="可见", ko="표시", ru="Видимые"),
    "Always in the menu bar": dict(de="Immer in der Menüleiste", fr="Toujours dans la barre des menus", es="Siempre en la barra de menús", it="Sempre nella barra dei menu", pt="Sempre na barra de menus", ja="常にメニューバーに表示", zh="始终显示在菜单栏", ko="항상 메뉴 막대에 표시", ru="Всегда в строке меню"),
    "Hidden": dict(de="Ausgeblendet", fr="Masqués", es="Ocultos", it="Nascosti", pt="Ocultos", ja="非表示", zh="隐藏", ko="숨김", ru="Скрытые"),
    "A hover or click away — or ⌘-drag icons left of the chevron": dict(de="Ein Überfahren oder Klick entfernt – oder Symbole mit ⌘ links neben den Chevron ziehen", fr="À un survol ou un clic : ou glissez des icônes à gauche du chevron avec ⌘", es="A un paso del cursor o un clic; o arrastra iconos con ⌘ a la izquierda del chevrón", it="A un passaggio del cursore o a un clic; oppure trascina le icone con ⌘ a sinistra del chevron", pt="A um passar de cursor ou clique; ou arraste ícones com ⌘ para a esquerda do chevron", ja="ホバーかクリックで表示。または⌘を押しながらアイコンをシェブロンの左へドラッグ", zh="悬停或点击即可显示，也可按住 ⌘ 将图标拖到尖角符号左侧", ko="마우스를 올리거나 클릭하면 표시. 또는 ⌘를 누른 채 아이콘을 쉐브론 왼쪽으로 드래그", ru="Показ по наведению или щелчку; либо перетащите значки левее шеврона с ⌘"),
    "Always Hidden": dict(de="Immer ausgeblendet", fr="Toujours masqués", es="Siempre ocultos", it="Sempre nascosti", pt="Sempre ocultos", ja="常に非表示", zh="始终隐藏", ko="항상 숨김", ru="Всегда скрытые"),
    "Out of sight until you double-click or ⌥-click the chevron": dict(de="Verborgen, bis du den Chevron doppelt oder mit ⌥ anklickst", fr="Hors de vue jusqu’à un double-clic ou un ⌥-clic sur le chevron", es="Fuera de la vista hasta que hagas doble clic o ⌥-clic en el chevrón", it="Fuori vista finché non fai doppio clic o ⌥-clic sul chevron", pt="Fora de vista até você dar clique duplo ou ⌥-clique no chevron", ja="シェブロンをダブルクリックまたは⌥クリックするまで非表示", zh="双击或按住 ⌥ 点击尖角符号之前一直隐藏", ko="쉐브론을 더블 클릭하거나 ⌥-클릭할 때까지 숨김", ru="Скрыты до двойного щелчка или ⌥-щелчка по шеврону"),
    "New menu bar icons go to": dict(de="Neue Menüleistensymbole landen in", fr="Les nouvelles icônes vont dans", es="Los iconos nuevos van a", it="Le nuove icone vanno in", pt="Ícones novos vão para", ja="新しいメニューバーアイコンの行き先", zh="新的菜单栏图标放入", ko="새 메뉴 막대 아이콘 위치", ru="Новые значки попадают в"),
    "Drop icons here": dict(de="Symbole hier ablegen", fr="Déposez des icônes ici", es="Suelta iconos aquí", it="Trascina qui le icone", pt="Solte ícones aqui", ja="ここにアイコンをドロップ", zh="将图标拖放到这里", ko="여기에 아이콘을 놓으세요", ru="Перетащите значки сюда"),
    "New": dict(de="Neu", fr="Nouveau", es="Nuevo", it="Nuovo", pt="Novo", ja="新規", zh="新", ko="새 항목", ru="Новые"),
    "New menu bar icons land here — drag into another section to change it": dict(de="Neue Menüleistensymbole landen hier – in einen anderen Bereich ziehen, um das zu ändern", fr="Les nouvelles icônes arrivent ici : glissez dans une autre section pour changer", es="Los iconos nuevos aparecen aquí; arrastra a otra sección para cambiarlo", it="Le nuove icone arrivano qui: trascina in un’altra sezione per cambiare", pt="Ícones novos chegam aqui; arraste para outra seção para mudar", ja="新しいアイコンはここに入ります。変更するには別のセクションへドラッグ", zh="新图标会放在这里，拖到其他分区可更改", ko="새 아이콘은 여기에 들어옵니다. 바꾸려면 다른 섹션으로 드래그하세요", ru="Новые значки попадают сюда: перетащите в другую секцию, чтобы изменить"),
    "Media": dict(de="Medien", fr="Médias", es="Multimedia", it="Media", pt="Mídia", ja="メディア", zh="媒体", ko="미디어", ru="Медиа"),
    "Camera": dict(de="Kamera", fr="Caméra", es="Cámara", it="Fotocamera", pt="Câmera", ja="カメラ", zh="相机", ko="카메라", ru="Камера"),
    "Separator": dict(de="Trenner", fr="Séparateur", es="Separador", it="Separatore", pt="Separador", ja="区切り", zh="分隔符", ko="구분선", ru="Разделитель"),
    "System": dict(de="System", fr="Système", es="Sistema", it="Sistema", pt="Sistema", ja="システム", zh="系统", ko="시스템", ru="Система"),
    "Icons from the same app hide together": dict(de="Symbole derselben App werden gemeinsam ausgeblendet", fr="Les icônes d’une même app se masquent ensemble", es="Los iconos de la misma app se ocultan juntos", it="Le icone della stessa app si nascondono insieme", pt="Ícones do mesmo app são ocultados juntos", ja="同じアプリのアイコンは一緒に隠れます", zh="同一应用的图标会一起隐藏", ko="같은 앱의 아이콘은 함께 숨겨집니다", ru="Значки одного приложения скрываются вместе"),
    "System icon — Pelmet places it; whether it exists in the bar is set in System Settings › Control Center": dict(de="Systemsymbol – Pelmet platziert es; ob es in der Leiste erscheint, wird in Systemeinstellungen › Kontrollzentrum festgelegt", fr="Icône système : Pelmet la place ; sa présence dans la barre se règle dans Réglages Système › Centre de contrôle", es="Icono del sistema: Pelmet lo coloca; si aparece en la barra se decide en Ajustes del Sistema › Centro de control", it="Icona di sistema: Pelmet la posiziona; la sua presenza nella barra si imposta in Impostazioni di Sistema › Centro di Controllo", pt="Ícone do sistema: o Pelmet o posiciona; se aparece na barra é definido em Ajustes do Sistema › Central de Controle", ja="システムアイコン。Pelmetが配置します。バーに表示するかは「システム設定」›「コントロールセンター」で設定", zh="系统图标，由 Pelmet 摆放；是否显示在菜单栏取决于“系统设置”›“控制中心”", ko="시스템 아이콘. Pelmet이 배치합니다. 막대에 표시할지는 시스템 설정 › 제어 센터에서 정합니다", ru="Системный значок: Pelmet его размещает; показывать ли его в строке, задаётся в Системных настройках › Пункт управления"),
    "Pelmet items": dict(de="Pelmet-Elemente", fr="Éléments Pelmet", es="Elementos de Pelmet", it="Elementi Pelmet", pt="Itens do Pelmet", ja="Pelmetの項目", zh="Pelmet 项目", ko="Pelmet 항목", ru="Элементы Pelmet"),
    "Pelmet-made stand-ins for the system extras — these live in any section": dict(de="Von Pelmet gebaute Ersatzsymbole für die System-Extras – sie passen in jeden Bereich", fr="Des doublures Pelmet pour les extras système : elles vont dans n’importe quelle section", es="Sustitutos hechos por Pelmet para los extras del sistema: caben en cualquier sección", it="Sostituti creati da Pelmet per gli extra di sistema: stanno in qualsiasi sezione", pt="Substitutos criados pelo Pelmet para os extras do sistema: ficam em qualquer seção", ja="システムの追加項目の代わりになるPelmet製の項目。どのセクションにも置けます", zh="Pelmet 制作的系统附加项替代品，可放在任意分区", ko="시스템 추가 항목을 대신하는 Pelmet 제작 항목. 어느 섹션에든 둘 수 있습니다", ru="Заменители системных элементов от Pelmet: их можно поместить в любую секцию"),
    "No shortcuts in your library": dict(de="Keine Kurzbefehle in deiner Mediathek", fr="Aucun raccourci dans votre bibliothèque", es="No hay atajos en tu biblioteca", it="Nessun comando rapido nella tua libreria", pt="Nenhum atalho na sua biblioteca", ja="ライブラリにショートカットがありません", zh="资料库中没有快捷指令", ko="보관함에 단축어가 없습니다", ru="В библиотеке нет быстрых команд"),
    "Shortcut": dict(de="Kurzbefehl", fr="Raccourci", es="Atajo", it="Comando rapido", pt="Atalho", ja="ショートカット", zh="快捷指令", ko="단축어", ru="Быстрая команда"),
    "Media controls": dict(de="Mediensteuerung", fr="Commandes multimédias", es="Controles multimedia", it="Controlli multimediali", pt="Controles de mídia", ja="メディアコントロール", zh="媒体控制", ko="미디어 제어", ru="Управление воспроизведением"),
    "Shows while audio plays (lingers a few minutes after) — click plays/pauses, right-click for tracks": dict(de="Erscheint bei Audiowiedergabe (bleibt danach einige Minuten) – Klick für Wiedergabe/Pause, Rechtsklick für Titel", fr="Apparaît pendant la lecture audio (reste quelques minutes après) : clic pour lecture/pause, clic droit pour les pistes", es="Aparece mientras suena audio (permanece unos minutos después): clic para reproducir/pausar, clic derecho para las pistas", it="Compare durante la riproduzione audio (resta qualche minuto dopo): clic per riproduci/pausa, clic destro per i brani", pt="Aparece enquanto toca áudio (fica alguns minutos depois): clique para tocar/pausar, clique direito para as faixas", ja="音声の再生中に表示（終了後も数分残ります）。クリックで再生/一時停止、右クリックで曲送り", zh="播放音频时显示（停止后保留几分钟）：点击播放/暂停，右键切换曲目", ko="오디오 재생 중 표시(종료 후 몇 분간 유지). 클릭으로 재생/일시정지, 오른쪽 클릭으로 트랙 이동", ru="Показывается во время воспроизведения (и ещё несколько минут после): щелчок — пуск/пауза, правый щелчок — треки"),
    "Camera & mic indicator": dict(de="Kamera- & Mikrofonanzeige", fr="Indicateur caméra et micro", es="Indicador de cámara y micro", it="Indicatore fotocamera e microfono", pt="Indicador de câmera e microfone", ja="カメラ＆マイクのインジケータ", zh="相机和麦克风指示器", ko="카메라 및 마이크 표시기", ru="Индикатор камеры и микрофона"),
    "Exists only while a camera or mic is live — its section just decides where it appears": dict(de="Existiert nur, während Kamera oder Mikrofon aktiv sind – der Bereich bestimmt nur, wo es erscheint", fr="N’existe que lorsqu’une caméra ou un micro est actif : sa section décide seulement où il apparaît", es="Solo existe mientras una cámara o un micro están activos: su sección solo decide dónde aparece", it="Esiste solo mentre una fotocamera o un microfono è attivo: la sezione decide solo dove compare", pt="Só existe enquanto uma câmera ou microfone está ativo: a seção apenas decide onde aparece", ja="カメラまたはマイクが使用中のときだけ存在します。セクションは表示位置を決めるだけです", zh="仅在相机或麦克风使用中时存在，分区只决定它出现的位置", ko="카메라나 마이크가 켜져 있을 때만 존재합니다. 섹션은 표시 위치만 정합니다", ru="Существует только пока активны камера или микрофон: секция лишь задаёт, где он появится"),
    "AirDrop": dict(de="AirDrop", fr="AirDrop", es="AirDrop", it="AirDrop", pt="AirDrop", ja="AirDrop", zh="隔空投送", ko="AirDrop", ru="AirDrop"),
    "Opens Finder's AirDrop view": dict(de="Öffnet die AirDrop-Ansicht des Finders", fr="Ouvre la vue AirDrop du Finder", es="Abre la vista AirDrop del Finder", it="Apre la vista AirDrop del Finder", pt="Abre a visualização AirDrop do Finder", ja="FinderのAirDrop画面を開きます", zh="打开访达的隔空投送视图", ko="Finder의 AirDrop 보기를 엽니다", ru="Открывает раздел AirDrop в Finder"),
    "Runs your shortcut": dict(de="Führt deinen Kurzbefehl aus", fr="Exécute votre raccourci", es="Ejecuta tu atajo", it="Esegue il tuo comando rapido", pt="Executa o seu atalho", ja="ショートカットを実行します", zh="运行你的快捷指令", ko="단축어를 실행합니다", ru="Запускает вашу быструю команду"),
    "Separators": dict(de="Trenner", fr="Séparateurs", es="Separadores", it="Separatori", pt="Separadores", ja="区切り", zh="分隔符", ko="구분선", ru="Разделители"),
    "Decorative dividers you can ⌘-drag anywhere in the bar": dict(de="Dekorative Trennlinien, die du mit ⌘ überall in der Leiste platzieren kannst", fr="Des séparateurs décoratifs à glisser n’importe où dans la barre avec ⌘", es="Divisores decorativos que puedes arrastrar con ⌘ a cualquier parte de la barra", it="Divisori decorativi che puoi trascinare con ⌘ ovunque nella barra", pt="Divisores decorativos que você pode arrastar com ⌘ para qualquer lugar da barra", ja="⌘を押しながらバーのどこへでもドラッグできる装飾用の区切り", zh="装饰性分隔线，可按住 ⌘ 拖到菜单栏任意位置", ko="⌘를 누른 채 막대 어디로든 드래그할 수 있는 장식용 구분선", ru="Декоративные разделители, которые можно перетаскивать с ⌘ в любое место строки"),
    "Add a separator": dict(de="Trenner hinzufügen", fr="Ajouter un séparateur", es="Añadir un separador", it="Aggiungi un separatore", pt="Adicionar um separador", ja="区切りを追加", zh="添加分隔符", ko="구분선 추가", ru="Добавить разделитель"),
    "Separator opacity in the menu bar": dict(de="Deckkraft des Trenners in der Menüleiste", fr="Opacité du séparateur dans la barre des menus", es="Opacidad del separador en la barra de menús", it="Opacità del separatore nella barra dei menu", pt="Opacidade do separador na barra de menus", ja="メニューバーでの区切りの不透明度", zh="分隔符在菜单栏中的不透明度", ko="메뉴 막대에서 구분선의 불투명도", ru="Непрозрачность разделителя в строке меню"),
    "Pipe": dict(de="Strich", fr="Barre verticale", es="Barra vertical", it="Barra verticale", pt="Barra vertical", ja="縦線", zh="竖线", ko="세로선", ru="Вертикальная черта"),
    "Dot": dict(de="Punkt", fr="Point", es="Punto", it="Punto", pt="Ponto", ja="ドット", zh="圆点", ko="점", ru="Точка"),
    "Chevron ‹": dict(de="Chevron ‹", fr="Chevron ‹", es="Chevrón ‹", it="Chevron ‹", pt="Chevron ‹", ja="シェブロン ‹", zh="尖角符号 ‹", ko="쉐브론 ‹", ru="Шеврон ‹"),
    "Chevron ›": dict(de="Chevron ›", fr="Chevron ›", es="Chevrón ›", it="Chevron ›", pt="Chevron ›", ja="シェブロン ›", zh="尖角符号 ›", ko="쉐브론 ›", ru="Шеврон ›"),
    "Dash": dict(de="Gedankenstrich", fr="Tiret", es="Guion", it="Trattino", pt="Travessão", ja="ダッシュ", zh="破折号", ko="대시", ru="Тире"),
    "Invisible spacer": dict(de="Unsichtbarer Abstand", fr="Espace invisible", es="Espaciador invisible", it="Spaziatore invisibile", pt="Espaçador invisível", ja="見えないスペース", zh="不可见间隔", ko="보이지 않는 간격", ru="Невидимый отступ"),

    # ── Onboarding ──────────────────────────────────────────────────
    "Back": dict(de="Zurück", fr="Retour", es="Atrás", it="Indietro", pt="Voltar", ja="戻る", zh="返回", ko="뒤로", ru="Назад"),
    "Continue": dict(de="Weiter", fr="Continuer", es="Continuar", it="Continua", pt="Continuar", ja="続ける", zh="继续", ko="계속", ru="Далее"),
    "Start using Pelmet": dict(de="Pelmet verwenden", fr="Commencer avec Pelmet", es="Empezar a usar Pelmet", it="Inizia a usare Pelmet", pt="Começar a usar o Pelmet", ja="Pelmetを使い始める", zh="开始使用 Pelmet", ko="Pelmet 사용 시작", ru="Начать работу с Pelmet"),
    "Your menu bar,\ntucked away.": dict(de="Deine Menüleiste,\naufgeräumt.", fr="Votre barre des menus,\nbien rangée.", es="Tu barra de menús,\nrecogida.", it="La tua barra dei menu,\nin ordine.", pt="Sua barra de menus,\nbem guardada.", ja="メニューバーを、\nすっきりと。", zh="你的菜单栏，\n收纳整齐。", ko="메뉴 막대를\n깔끔하게 정리.", ru="Строка меню,\nубранная с глаз."),
    "Pelmet keeps every icon a hover away — and the ones you never need, out of sight.": dict(de="Pelmet hält jedes Symbol ein Überfahren entfernt – und die, die du nie brauchst, außer Sicht.", fr="Pelmet garde chaque icône à un survol, et celles dont vous n’avez jamais besoin, hors de vue.", es="Pelmet mantiene cada icono a un paso del cursor, y los que nunca necesitas, fuera de la vista.", it="Pelmet tiene ogni icona a un passaggio del cursore, e quelle che non ti servono mai, fuori vista.", pt="O Pelmet mantém cada ícone a um passar de cursor, e os que você nunca precisa, fora de vista.", ja="Pelmetはすべてのアイコンをホバー一つで呼び出せるようにし、不要なものは視界から隠します。", zh="Pelmet 让每个图标悬停即现，而那些你从不需要的，则藏于视线之外。", ko="Pelmet은 모든 아이콘을 마우스 한 번에 불러오고, 필요 없는 것은 시야 밖으로 치웁니다.", ru="Pelmet держит каждый значок в одном наведении, а те, что не нужны никогда, — вне поля зрения."),
    "One permission.": dict(de="Eine Berechtigung.", fr="Une seule autorisation.", es="Un solo permiso.", it="Un solo permesso.", pt="Uma permissão.", ja="必要な許可はひとつ。", zh="只需一项权限。", ko="권한 하나면 됩니다.", ru="Одно разрешение."),
    "Pelmet arranges your menu bar through macOS accessibility — that's how it sees the icons and moves them. Nothing is read from your screen, nothing leaves your Mac.": dict(
        de="Pelmet ordnet deine Menüleiste über die Bedienungshilfen von macOS – so sieht es die Symbole und verschiebt sie. Nichts wird von deinem Bildschirm gelesen, nichts verlässt deinen Mac.",
        fr="Pelmet organise votre barre des menus via l’accessibilité de macOS : c’est ainsi qu’il voit les icônes et les déplace. Rien n’est lu sur votre écran, rien ne quitte votre Mac.",
        es="Pelmet organiza tu barra de menús mediante la accesibilidad de macOS: así ve los iconos y los mueve. No lee nada de tu pantalla y nada sale de tu Mac.",
        it="Pelmet organizza la barra dei menu tramite l’accessibilità di macOS: è così che vede le icone e le sposta. Non legge nulla dallo schermo e nulla lascia il tuo Mac.",
        pt="O Pelmet organiza sua barra de menus pela acessibilidade do macOS: é assim que ele vê os ícones e os move. Nada é lido da sua tela, nada sai do seu Mac.",
        ja="PelmetはmacOSのアクセシビリティを通じてメニューバーを整えます。それによってアイコンを認識し、移動します。画面の内容を読み取ることはなく、Macの外にデータが出ることもありません。",
        zh="Pelmet 通过 macOS 辅助功能整理菜单栏，它借此识别并移动图标。不会读取你的屏幕内容，任何数据都不会离开你的 Mac。",
        ko="Pelmet은 macOS 손쉬운 사용을 통해 메뉴 막대를 정리합니다. 그렇게 아이콘을 인식하고 옮깁니다. 화면을 읽지 않으며, 어떤 데이터도 Mac 밖으로 나가지 않습니다.",
        ru="Pelmet упорядочивает строку меню через Универсальный доступ macOS: так он видит значки и перемещает их. Ничего не считывается с экрана, ничего не покидает ваш Mac."),
    "Access granted": dict(de="Zugriff gewährt", fr="Accès accordé", es="Acceso concedido", it="Accesso concesso", pt="Acesso concedido", ja="アクセスが許可されました", zh="已授权", ko="접근 허용됨", ru="Доступ предоставлен"),
    "Grant Accessibility Access": dict(de="Bedienungshilfen-Zugriff erlauben", fr="Autoriser l’accessibilité", es="Conceder acceso de accesibilidad", it="Consenti l’accessibilità", pt="Conceder acesso de acessibilidade", ja="アクセシビリティを許可", zh="授予辅助功能权限", ko="손쉬운 사용 접근 허용", ru="Разрешить Универсальный доступ"),
    "Drag the icon left\nof the chevron.": dict(de="Zieh das Symbol links\nneben den Chevron.", fr="Glissez l’icône\nà gauche du chevron.", es="Arrastra el icono\na la izquierda del chevrón.", it="Trascina l’icona\na sinistra del chevron.", pt="Arraste o ícone\npara a esquerda do chevron.", ja="アイコンをシェブロンの\n左へドラッグ。", zh="把图标拖到\n尖角符号左侧。", ko="아이콘을 쉐브론\n왼쪽으로 드래그.", ru="Перетащите значок\nлевее шеврона."),
    "That's the whole trick.": dict(de="Das ist der ganze Trick.", fr="C’est tout le secret.", es="Ese es todo el truco.", it="Tutto qui.", pt="É só isso.", ja="コツはそれだけ。", zh="就这么简单。", ko="비결은 이게 전부입니다.", ru="Вот и весь секрет."),
    "The chevron is the boundary: everything left of it tucks away.": dict(de="Der Chevron ist die Grenze: Alles links davon wird verstaut.", fr="Le chevron est la frontière : tout ce qui est à sa gauche se range.", es="El chevrón es la frontera: todo lo que queda a su izquierda se recoge.", it="Il chevron è il confine: tutto ciò che sta a sinistra si ripiega.", pt="O chevron é a fronteira: tudo à esquerda dele se recolhe.", ja="シェブロンが境界です。その左にあるものはすべて隠れます。", zh="尖角符号就是分界线：它左侧的一切都会收起。", ko="쉐브론이 경계입니다. 왼쪽의 모든 것이 숨겨집니다.", ru="Шеврон — это граница: всё левее него прячется."),
    "Left of the chevron hides, right stays. In your real bar, hold ⌘ while dragging — or arrange everything in Pelmet's settings.": dict(
        de="Links vom Chevron wird ausgeblendet, rechts bleibt sichtbar. In deiner echten Leiste hältst du beim Ziehen ⌘ gedrückt – oder ordnest alles in den Pelmet-Einstellungen.",
        fr="À gauche du chevron, masqué ; à droite, visible. Dans votre vraie barre, maintenez ⌘ en glissant, ou organisez tout dans les réglages de Pelmet.",
        es="A la izquierda del chevrón se oculta, a la derecha se queda. En tu barra real, mantén ⌘ mientras arrastras, o colócalo todo desde los ajustes de Pelmet.",
        it="A sinistra del chevron si nasconde, a destra resta. Nella barra vera tieni premuto ⌘ mentre trascini, oppure sistema tutto nelle impostazioni di Pelmet.",
        pt="À esquerda do chevron fica oculto, à direita fica visível. Na sua barra real, segure ⌘ ao arrastar, ou organize tudo nos ajustes do Pelmet.",
        ja="シェブロンの左は隠れ、右は残ります。実際のバーでは⌘を押しながらドラッグするか、Pelmetの設定ですべてを並べ替えられます。",
        zh="尖角符号左侧隐藏，右侧保留。在真实菜单栏中，拖动时按住 ⌘，或在 Pelmet 设置中统一安排。",
        ko="쉐브론 왼쪽은 숨고 오른쪽은 남습니다. 실제 막대에서는 ⌘를 누른 채 드래그하거나, Pelmet 설정에서 모두 정리하세요.",
        ru="Левее шеврона — скрыто, правее — видно. В настоящей строке удерживайте ⌘ при перетаскивании или расставьте всё в настройках Pelmet."),
    "Settled in.": dict(de="Eingerichtet.", fr="Bien installé.", es="Todo listo.", it="Tutto a posto.", pt="Tudo pronto.", ja="準備完了。", zh="一切就绪。", ko="준비 완료.", ru="Всё готово."),
    "Hover the bar to peek, click the chevron to toggle, right-click it for settings. Everything else is arrangeable in Pelmet Settings › Menu Bar.": dict(
        de="Leiste überfahren zum Spicken, Chevron anklicken zum Umschalten, Rechtsklick für die Einstellungen. Alles Weitere ordnest du unter Pelmet-Einstellungen › Menüleiste.",
        fr="Survolez la barre pour jeter un œil, cliquez sur le chevron pour basculer, clic droit pour les réglages. Tout le reste s’organise dans Réglages de Pelmet › Barre des menus.",
        es="Pasa el cursor por la barra para echar un vistazo, haz clic en el chevrón para alternar y clic derecho para los ajustes. Todo lo demás se organiza en Ajustes de Pelmet › Barra de menús.",
        it="Passa il cursore sulla barra per sbirciare, fai clic sul chevron per alternare, clic destro per le impostazioni. Tutto il resto si sistema in Impostazioni di Pelmet › Barra dei menu.",
        pt="Passe o cursor na barra para espiar, clique no chevron para alternar, clique com o botão direito para os ajustes. Todo o resto se organiza em Ajustes do Pelmet › Barra de menus.",
        ja="バーにホバーでちらっと表示、シェブロンをクリックで切り替え、右クリックで設定。その他はすべて「Pelmet設定」›「メニューバー」で並べ替えられます。",
        zh="悬停菜单栏可快速查看，点击尖角符号切换，右键打开设置。其余一切可在 Pelmet 设置 › 菜单栏中安排。",
        ko="막대에 마우스를 올려 살짝 보고, 쉐브론을 클릭해 전환하고, 오른쪽 클릭으로 설정을 엽니다. 나머지는 모두 Pelmet 설정 › 메뉴 막대에서 정리할 수 있습니다.",
        ru="Наведите на строку, чтобы взглянуть, щёлкните шеврон для переключения, правый щелчок — настройки. Всё остальное настраивается в Настройки Pelmet › Строка меню."),
    "Open Pelmet at login": dict(de="Pelmet bei der Anmeldung öffnen", fr="Ouvrir Pelmet à l’ouverture de session", es="Abrir Pelmet al iniciar sesión", it="Apri Pelmet al login", pt="Abrir o Pelmet ao iniciar sessão", ja="ログイン時にPelmetを開く", zh="登录时打开 Pelmet", ko="로그인 시 Pelmet 열기", ru="Открывать Pelmet при входе"),
    "Drag me left of the chevron": dict(de="Zieh mich links neben den Chevron", fr="Glissez-moi à gauche du chevron", es="Arrástrame a la izquierda del chevrón", it="Trascinami a sinistra del chevron", pt="Arraste-me para a esquerda do chevron", ja="シェブロンの左へドラッグしてください", zh="把我拖到尖角符号左侧", ko="쉐브론 왼쪽으로 드래그하세요", ru="Перетащите меня левее шеврона"),

    # ── Status item menu ────────────────────────────────────────────
    "Hide Items": dict(de="Objekte ausblenden", fr="Masquer les éléments", es="Ocultar elementos", it="Nascondi elementi", pt="Ocultar itens", ja="項目を隠す", zh="隐藏项目", ko="항목 숨기기", ru="Скрыть элементы"),
    "Show Hidden Items": dict(de="Ausgeblendete Objekte einblenden", fr="Afficher les éléments masqués", es="Mostrar elementos ocultos", it="Mostra elementi nascosti", pt="Mostrar itens ocultos", ja="隠した項目を表示", zh="显示隐藏的项目", ko="숨긴 항목 표시", ru="Показать скрытые элементы"),
    "Show Always-Hidden Too": dict(de="Auch „Immer ausgeblendet“ einblenden", fr="Afficher aussi les toujours masqués", es="Mostrar también los siempre ocultos", it="Mostra anche i sempre nascosti", pt="Mostrar também os sempre ocultos", ja="「常に非表示」も表示", zh="同时显示“始终隐藏”的项目", ko="항상 숨김 항목도 표시", ru="Показать и всегда скрытые"),
    "Pelmet Settings…": dict(de="Pelmet-Einstellungen …", fr="Réglages de Pelmet…", es="Ajustes de Pelmet…", it="Impostazioni di Pelmet…", pt="Ajustes do Pelmet…", ja="Pelmet設定…", zh="Pelmet 设置…", ko="Pelmet 설정…", ru="Настройки Pelmet…"),
    "Quit Pelmet": dict(de="Pelmet beenden", fr="Quitter Pelmet", es="Salir de Pelmet", it="Esci da Pelmet", pt="Encerrar o Pelmet", ja="Pelmetを終了", zh="退出 Pelmet", ko="Pelmet 종료", ru="Завершить Pelmet"),

    # ── Media / camera extras ───────────────────────────────────────
    "Previous Track": dict(de="Vorheriger Titel", fr="Piste précédente", es="Pista anterior", it="Brano precedente", pt="Faixa anterior", ja="前の曲", zh="上一曲", ko="이전 트랙", ru="Предыдущий трек"),
    "Next Track": dict(de="Nächster Titel", fr="Piste suivante", es="Pista siguiente", it="Brano successivo", pt="Próxima faixa", ja="次の曲", zh="下一曲", ko="다음 트랙", ru="Следующий трек"),
    "Camera & Mic": dict(de="Kamera & Mikrofon", fr="Caméra et micro", es="Cámara y micro", it="Fotocamera e microfono", pt="Câmera e microfone", ja="カメラ＆マイク", zh="相机和麦克风", ko="카메라 및 마이크", ru="Камера и микрофон"),
}

LANG_CODES = {"de": "de", "fr": "fr", "es": "es", "it": "it", "pt": "pt-BR", "ja": "ja", "zh": "zh-Hans", "ko": "ko", "ru": "ru"}


def main() -> None:
    strings = {}
    for key, langs in T.items():
        missing = set(LANG_CODES) - set(langs)
        assert not missing, f"{key!r} missing {missing}"
        strings[key] = {
            "localizations": {
                LANG_CODES[code]: {"stringUnit": {"state": "translated", "value": value}}
                for code, value in langs.items()
            }
        }
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"{len(strings)} keys × {len(LANG_CODES)} languages → {OUT.relative_to(OUT.parents[2])}")


if __name__ == "__main__":
    main()
