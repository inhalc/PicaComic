part of pica_settings;

class SetJmComicsOrderController extends StateController{
  int settingsOrder;
  SetJmComicsOrderController(this.settingsOrder);
  late String value = appdata.settings[settingsOrder];

  void set(String v){
    value = v;
    appdata.settings[settingsOrder] = v;
    appdata.writeData();
    App.globalBack();
  }
}


class JmSettings extends StatefulWidget {
  const JmSettings(this.popUp, {Key? key}) : super(key: key);
  final bool popUp;

  @override
  State<JmSettings> createState() => _JmSettingsState();

  static const builtInApiDomains = <String>[
    "www.cdntwice.org",
    "www.cdnsha.org",
    "www.cdnaspa.cc",
    "www.cdnntr.cc"
  ];

  static void updateApiDomains([bool showLoading = false]) async {
    var title = "";
    var msg = "";
    List<String> domains = builtInApiDomains;
    var controller = showLoading ? showLoadingDialog(App.globalContext!) : null;
    var res = await JmNetwork().getApiDomains();
    if (res.error) {
      title += "更新失败".tl;
      msg += "${"使用内置域名:".tl}\n";
    } else {
      title += "更新成功".tl;
      domains = res.data;
    }
    controller?.close();
    for (String domain in domains) {
        msg += "${"域名".tl}${domains.indexOf(domain) + 1}: $domain\n";
    }
    msg = msg.trim();
    showConfirmDialog(App.globalContext!, title, msg, () async {
      appdata.appSettings.jmApiDomains = domains;
      await updateAppVersionCode();
      JmNetwork().loginFromAppdata();
    });
  }

  static void daily([bool showLoading = false]) async {
    if (!jm.isLogin && showLoading) {
      showToast(message: "未登录".tl);
      return;
    }
    var controller = showLoading ? showLoadingDialog(App.globalContext!) : null;
    var res = await JmNetwork().dailyChk();
    controller?.close();
    var title = res.success ? "签到成功".tl : "签到失败".tl;
    var msg = res.success ? "${res.subData}".tl : res.errorMessage;
    if (showLoading) showDialogMessage(App.globalContext!, title, msg!);
  }

  static Future<void> updateAppVersionCode() async {
    var res = await JmNetwork().getAppVersionCode();
    if (!res.error) {
      appdata.settings[89] = res.data;
      appdata.updateSettings();
    }
  }

  /// Lets the user point the domain update at their own mirror (#226).
  ///
  /// The two built-in hosts are plain object storage URLs, which are exactly
  /// what gets blocked in the networks where the update fails, so a mirror is
  /// often the only way to refresh the domain list at all.
  static Future<void> editUpdateUrls(BuildContext context) async {
    var controller = TextEditingController(
        text: appdata.appSettings.jmApiUpdateUrls.join('\n'));
    await showDialog(
      context: context,
      useSafeArea: false,
      builder: (context) => ContentDialog(
        title: "自定义更新地址".tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "留空则只使用内置地址。每行一个地址, 可以是自建镜像。".tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: "https://example.com/newsvr.txt",
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ).paddingHorizontal(16),
        actions: [
          Button.filled(
            child: Text("保存".tl),
            onPressed: () {
              appdata.appSettings.jmApiUpdateUrls =
                  parseJmUpdateUrlInput(controller.text);
              appdata.updateSettings();
              context.pop();
            },
          )
        ],
      ),
    );
  }

  /// Lets the user type the API domains instead of downloading them (#226).
  static Future<void> editApiDomains(BuildContext context) async {
    var controller = TextEditingController(
        text: appdata.appSettings.jmApiDomains.join('\n'));
    await showDialog(
      context: context,
      useSafeArea: false,
      builder: (context) => ContentDialog(
        title: "手动设置API域名".tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "每行一个域名, 不带 https:// 。第一行为分流1, 依次类推。".tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: "www.example.org",
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ).paddingHorizontal(16),
        actions: [
          Button.filled(
            child: Text("保存".tl),
            onPressed: () {
              final domains = parseJmDomainInput(controller.text);
              if (domains.isEmpty) {
                showToast(message: "域名不能为空".tl);
                return;
              }
              appdata.appSettings.jmApiDomains = domains;
              // The selected index must stay inside the new list, otherwise
              // every request would throw on `domains[index]`.
              final selected = int.tryParse(appdata.settings[17]);
              if (selected == null || selected >= domains.length) {
                appdata.settings[17] = "0";
              }
              appdata.updateSettings();
              updateAppVersionCode();
              JmNetwork().loginFromAppdata();
              context.pop();
            },
          )
        ],
      ),
    );
  }
}

class _JmSettingsState extends State<JmSettings> {
  bool autoSelectStream = appdata.settings[15] == "1";
  bool autoCheckIn = appdata.settings[88] == "1";

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: Text("禁漫天堂".tl),
        ),
        ListTile(
          leading: const Icon(Icons.track_changes),
          title: Text("自动选择域名".tl),
          subtitle: Text("登录时自动选择API域名".tl),
          trailing: Switch(
            value: autoSelectStream,
            onChanged: (b){
              b ? appdata.settings[15] = "1" : appdata.settings[15] = "0";
              setState(() {
                autoSelectStream = b;
              });
              appdata.updateSettings();
              if (autoSelectStream) JmNetwork().loginFromAppdata();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.dns),
          title: Text("API域名".tl),
          trailing: IgnorePointer(
            ignoring: autoSelectStream,
            child: Opacity(
              opacity: !autoSelectStream ? 1.0 : 0.5,
              child: Select(
                initialValue: int.parse(appdata.settings[17]),
                values: [
                  "分流1".tl,"分流2".tl,"分流3".tl,"分流4".tl,
                ],
                onChange: (i){
                  appdata.settings[17] = i.toString();
                  appdata.updateSettings();
                  JmNetwork().loginFromAppdata();
                },
              ),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text("图片分流".tl),
          trailing: Select(
            initialValue: int.parse(appdata.appSettings.jmImgUrlIndex),
            values: [
              "分流1".tl,"分流2".tl,"分流3".tl,"分流4".tl
            ],
            onChange: (i){
              appdata.settings[37] = i.toString();
              appdata.updateSettings();
              if (jm.isLogin) JmNetwork().updateImgUrl(i + 1);
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.favorite_border),
          title: Text("收藏夹漫画排序模式".tl),
          trailing: Select(
            initialValue: int.parse(appdata.settings[42]),
            width: App.locale.languageCode == "en" ? 130 : 120,
            values: [
              "最新收藏".tl, "最新更新".tl
            ],
            onChange: (i){
              appdata.settings[42] = i.toString();
              appdata.updateSettings();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.update_outlined),
          title: Text("更新API域名".tl),
          onTap: () => JmSettings.updateApiDomains(true),
          trailing: const Icon(Icons.arrow_right),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_sync_outlined),
          title: Text("自定义更新地址".tl),
          subtitle: Text("内置地址不可达时使用".tl),
          onTap: () => JmSettings.editUpdateUrls(context),
          trailing: const Icon(Icons.arrow_right),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text("手动设置API域名".tl),
          subtitle: Text("无法更新域名时直接填写".tl),
          onTap: () => JmSettings.editApiDomains(context),
          trailing: const Icon(Icons.arrow_right),
        ),
        ListTile(
          leading: const Icon(Icons.today),
          title: Text("自动签到".tl),
          subtitle: Text("勾选启用, 点击测试".tl),
          onTap: () => JmSettings.daily(true),
          trailing: Switch(
            value: autoCheckIn,
            onChanged: (b){
              b ? appdata.settings[88] = "1" : appdata.settings[88] = "0";
              setState(() {
                autoCheckIn = b;
              });
              appdata.updateSettings();
              if (autoCheckIn && jm.isLogin) JmSettings.daily(false);
            },
          ),
        ),
      ],
    );
  }
}