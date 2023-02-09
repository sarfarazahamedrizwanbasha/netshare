import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:netshare/config/styles.dart';
import 'package:netshare/repository/file_repository.dart';
import 'package:netshare/service/download_service.dart';
import 'package:netshare/data/hivedb/clients/shared_file_client.dart';
import 'package:netshare/entity/connection_status.dart';
import 'package:netshare/entity/download/download_entity.dart';
import 'package:netshare/entity/download/download_manner.dart';
import 'package:netshare/entity/download/download_state.dart';
import 'package:netshare/entity/shared_file_entity.dart';
import 'package:netshare/provider/connection_provider.dart';
import 'package:netshare/ui/client/connect_widget.dart';
import 'package:netshare/ui/client/navigation_widget.dart';
import 'package:netshare/util/utility_functions.dart';
import 'package:provider/provider.dart';
import 'package:netshare/di/di.dart';
import 'package:netshare/provider/file_provider.dart';
import 'package:netshare/ui/list_file/list_shared_files_widget.dart';
import 'package:netshare/util/extension.dart';

class ClientWidget extends StatefulWidget {
  const ClientWidget({super.key});

  @override
  State<ClientWidget> createState() => _ClientWidgetState();
}

class _ClientWidgetState extends State<ClientWidget> {

  final ReceivePort _port = ReceivePort();
  final fileRepository = getIt.get<FileRepository>();

  @override
  void initState() {
    super.initState();
    // always fetch list files when first open Home screen
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      final files = (await fileRepository.getSharedFilesWithState()).getOrElse(() => {});
      if (mounted) {
        context.read<FileProvider>().addAllSharedFiles(sharedFiles: files);
      }
    });
    _initDownloadModule();
    _downloadStreamListener();
  }

  void _initDownloadModule() {
    if (UtilityFunctions.isMobile) {
      try {
        IsolateNameServer.registerPortWithName(_port.sendPort, 'downloader_send_port');
        _port.listen((dynamic data) async {

          // TODO: 2. Flutter engine issue: can only send basic dart type
          // convert int to a custom state
          DownloadState state = (data[1] as int).toDownloadState;

          // only update state when finished, less update, less memory usage
          if(DownloadState.downloading != state) {
            String taskId = data[0];
            final tasks = await FlutterDownloader.loadTasksWithRawQuery(
              query: "SELECT * FROM task WHERE task_id = \"$taskId\"",
            );
            String? fileName;
            String? url;
            String? savedDir;
            if (null != tasks) {
              final task = tasks.firstWhere((element) => taskId == element.taskId);
              fileName = task.filename;
              url = task.url;
              savedDir = task.savedDir;
            }
            getIt.get<DownloadService>().updateDownloadState(
                DownloadEntity(
                  taskId,
                  fileName ?? '',
                  url ?? '',
                  savedDir ?? '',
                  DownloadManner.flutterDownloader,
                  state,
                )
            );
          }
        });
        FlutterDownloader.registerCallback(downloadCallback);
      } catch (e) {
        debugPrint(e.toString());
      }
    }
  }

  void _downloadStreamListener() {
    getIt.get<DownloadService>().downloadStream.listen((downloadEntity) {
      debugPrint("[DownloadService] Download stream log: $downloadEntity");

      // update state to the list files
      if (mounted) {
        context.read<FileProvider>().updateFile(
          fileName: downloadEntity.fileName,
          newFileState: downloadEntity.state.toSharedFileState,
          savedDir: downloadEntity.savedDir,
        );
      }

      // add succeed file to Hive database
      if (downloadEntity.state == DownloadState.succeed) {
        getIt.get<SharedFileClient>().add(
              SharedFile(
                name: downloadEntity.fileName,
                url: downloadEntity.url,
                savedDir: downloadEntity.savedDir,
                state: DownloadState.succeed.toSharedFileState,
              ),
            );
      }
    });
  }

  @pragma('vm:entry-point')
  static void downloadCallback(
    String id,
    DownloadTaskStatus status,
    int progress,
  ) {
    debugPrint(
      'Callback on background isolate: '
      'task ($id) is in status ($status) and process ($progress)',
    );
    // TODO: 1. Flutter engine issue: can only send basic dart type + restart/hot reload does not work
    //  (https://github.com/flutter/flutter/issues/119589)
    //  can only send basic dart type -> Fix: convert status entity to int
    IsolateNameServer.lookupPortByName('downloader_send_port')?.send([id, status.value, progress]);
  }

  @override
  void dispose() {
    if (UtilityFunctions.isMobile) {
      IsolateNameServer.removePortNameMapping('downloader_send_port');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectionProvider>(builder: (BuildContext ct, value, Widget? child) {
      final connectionStatus = value.connectionStatus;
      final connectedIPAddress = value.connectedIPAddress;
      return Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: connectionStatus == ConnectionStatus.connected
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    connectionStatus == ConnectionStatus.connected
                        ? const Icon(Icons.circle, size: 12.0, color: Colors.green)
                        : const Icon(Icons.circle, size: 12.0, color: Colors.grey),
                    const SizedBox(width: 6.0),
                    Text(
                      connectedIPAddress,
                      style: CommonTextStyle.textStyleNormal.copyWith(color: Colors.white),
                    ),
                  ],
                )
              : Text(
                  'NetShare',
                  style: CommonTextStyle.textStyleNormal.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: 18.0,
                  ),
                ),
          leading: UtilityFunctions.isDesktop
              ? IconButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  icon: const Icon(
                    Icons.arrow_back_ios_new,
                    color: Colors.white,
                  ),
                )
              : null,
          actions: [
            connectionStatus == ConnectionStatus.connected
                ? IconButton(
                    onPressed: () {
                      context.read<ConnectionProvider>().disconnect();
                      context.read<FileProvider>().clearAllFiles();
                    },
                    icon: const Icon(Icons.link_off),
                  )
                : IconButton(
                    onPressed: () => _onClickManualButton(),
                    icon: const Icon(Icons.link),
                  ),
          ],
        ),
        body: Column(
          children: [
            NavigationWidgets(connectionStatus: connectionStatus),
            const Expanded(child: ListSharedFiles()),
            _buildConnectOptions(),
          ],
        ),
      );
    });
  }

  _buildConnectOptions() => Container(
    margin: const EdgeInsets.only(bottom: 12.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // FloatingActionButton.extended(
            //   heroTag: const Text("Scan"),
            //   onPressed: () => _onClickScanButton(),
            //   label: const Text('Scan to connect'),
            //   icon: const Icon(Icons.qr_code_scanner),
            // ),
            // const SizedBox(width: 20.0),
            FloatingActionButton.extended(
              heroTag: const Text("Manual"),
              onPressed: () => _onClickManualButton(),
              label: Text(
                'Manual connect',
                style: CommonTextStyle.textStyleNormal.copyWith(color: Colors.black),
              ),
              icon: const Icon(Icons.account_tree),
            ),
          ],
        ),
  );

  // void _onClickScanButton() {
  //   context.go(Utilities.getRoutePath(name: mScanningWidget));
  // }

  void _onClickManualButton() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (bsContext) {
        return ConnectWidget(onConnected: () async {
          Navigator.pop(context);

          // auto reload files
          final files = (await fileRepository.getSharedFilesWithState()).getOrElse(() => {});
          if (mounted) {
          context.read<FileProvider>().addAllSharedFiles(sharedFiles: files);
          }
        });
      },
    );
  }
}
