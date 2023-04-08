import 'package:bubble/bubble.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:pocket_ai/src/constants.dart';
import 'package:pocket_ai/src/globals.dart';
import 'package:pocket_ai/src/modules/chat/chat_actions.dart';
import 'package:pocket_ai/src/modules/chat/models/chat_message.dart';
import 'package:pocket_ai/src/modules/faqs/screens/faqs_screen.dart';
import 'package:pocket_ai/src/modules/settings/screens/settings_screen.dart';
import 'package:pocket_ai/src/utils/analytics.dart';
import 'package:pocket_ai/src/utils/common.dart';
import 'package:pocket_ai/src/widgets/custom_colors.dart';
import 'package:pocket_ai/src/widgets/custom_text.dart';
import 'package:pocket_ai/src/widgets/custom_text_form_field.dart';
import 'package:pocket_ai/src/widgets/heading.dart';

class ChatScreen extends StatefulWidget {
  static const routeName = '/chat';

  const ChatScreen({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _ChatScreen();
}

class _ChatScreen extends State<ChatScreen> {
  List<ChatMessage> chatMessages = [
    ChatMessage(content: AiBotConstants.introMessage, role: ChatRole.assistant)
  ];
  bool apiCallInProgress = false;
  FirebaseFirestore db = FirebaseFirestore.instance;

  // consider last n messages for building context
  int lastMessagesCountForContext = 4;

  TextEditingController userMessageController = TextEditingController();
  ScrollController listViewontroller = ScrollController();

  @override
  void initState() {
    super.initState();
    logEvent(EventNames.chatScreenViewed, {});

    // if user hasn't set his own api key then get one from Firestore
    // only upto 5 sessions
    if (Globals.appSettings.openAiApiKey == null ||
        Globals.appSettings.openAiApiKey == '') {
      String? deviceId = Globals.deviceId;
      // todo: would deviceId ever be null?
      if (deviceId != null) {
        DocumentReference<Map<String, dynamic>> documentRef = db
            .collection(FirestoreCollectionsConst.userSessionsCount)
            .doc(deviceId);
        // get session count
        documentRef.get().then((response) {
          Map<String, dynamic>? data = response.data();
          int sessionCount = data == null ? 0 : data['count'];
          if (sessionCount <= 5) {
            // get open AI key and set to Globals
            db
                .collection(FirestoreCollectionsConst.openAiApiKeys)
                .get()
                .then((response) {
              if (response.docs.isNotEmpty) {
                Map<String, dynamic>? data = response.docs[0].data();
                Globals.freeOpenAiApiKey = data['apiKey'];
                Globals.appSettings.openAiApiKey = data['apiKey'];
              }
            }).catchError((error) {
              showSnackBar(context, message: error.toString());
            });
          }
          // increase the session count in Firestore
          documentRef.set({
            'count': sessionCount + 1,
            'createdAt': (data == null || data['createdAt'] == null)
                ? FieldValue.serverTimestamp()
                : data['createdAt']
          });
        }).catchError((error) {
          showSnackBar(context, message: error.toString());
        });
      }
    }
  }

  void onChatMessageLongPress(ChatMessage chatItem) {
    Clipboard.setData(ClipboardData(text: chatItem.content)).then((value) {
      showToastMessage('Copied to Clipboard');
    });
  }

  void saveUserMessageToFirestore(String userMessage) {
    // store user queries to Firestore for study & analytics
    String? deviceId = Globals.deviceId;
    if (deviceId != null) {
      db
          .collection(FirestoreCollectionsConst.userMessagesToBot)
          .doc(deviceId)
          .collection(FirestoreCollectionsConst.messages)
          .doc()
          .set({'message': userMessage, 'time': FieldValue.serverTimestamp()});
    }
  }

  void onSendPress() {
    String userMessage = userMessageController.text;
    if (userMessage.isEmpty) {
      return;
    }
    logEvent(EventNames.sendMessageClicked, {});

    // create context from previous chat, consider only last n messages
    // so that we don't run out of tokens limit
    List<ChatMessage> lastNMessages = [];
    int messageStartIndex =
        chatMessages.length - lastMessagesCountForContext >= 0
            ? (chatMessages.length - lastMessagesCountForContext)
            : 0;
    for (int i = messageStartIndex; i < chatMessages.length; i++) {
      lastNMessages.add(chatMessages[i]);
    }

    setState(() {
      chatMessages = [
        ...chatMessages,
        ChatMessage(content: userMessage, role: ChatRole.user)
      ];
      apiCallInProgress = true;
    });
    userMessageController.text = '';

    // adding delay so that list view is scrolled after setState re-render has been completed
    Future.delayed(const Duration(milliseconds: 100), () {
      listViewontroller.jumpTo(listViewontroller.position.maxScrollExtent);
    });
    saveUserMessageToFirestore(userMessage);

    getResponseFromOpenAi([
      ...lastNMessages,
      ChatMessage(content: userMessage, role: ChatRole.user)
    ]).then((response) {
      String botMessage = '${response['choices'][0]['message']['content']}';
      setState(() {
        chatMessages = [
          ...chatMessages,
          ChatMessage(content: botMessage, role: ChatRole.assistant)
        ];
      });
      logEvent(EventNames.openAiResponseSuccess, {});
    }).catchError((error) {
      logApiErrorAndShowMessage(context, exception: error);
      logEvent(EventNames.openAiResponseFailed, {});
    }).then((value) {
      setState(() {
        apiCallInProgress = false;
      });
      Future.delayed(const Duration(milliseconds: 100), () {
        listViewontroller.jumpTo(listViewontroller.position.maxScrollExtent);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Heading(
            'Pocket AI',
            type: HeadingType.h4,
          ),
          backgroundColor: CustomColors.darkBackground,
          actions: <Widget>[
            IconButton(
                tooltip: 'Help',
                onPressed: (() {
                  logEvent(EventNames.helpIconClicked, {});
                  navigateToScreen(context, FaqsScreen.routeName);
                }),
                icon: const Icon(Icons.help)),
            IconButton(
                tooltip: 'Settings',
                onPressed: (() {
                  logEvent(EventNames.settingsIconClicked, {});
                  navigateToScreen(context, SettingsScreen.routeName);
                }),
                icon: const Icon(Icons.settings))
          ]),
      body: Stack(children: [
        Container(
            margin: const EdgeInsets.only(bottom: 72),
            child: ListView.builder(
                controller: listViewontroller,
                itemCount: chatMessages.length,
                shrinkWrap: true,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 12, bottom: 12),
                itemBuilder: (context, index) {
                  var chatItem = chatMessages[index];
                  bool fromBot = chatItem.role == ChatRole.assistant;
                  return GestureDetector(
                    onLongPress: () {
                      onChatMessageLongPress(chatItem);
                    },
                    child: Bubble(
                        nip: fromBot ? BubbleNip.leftTop : BubbleNip.rightTop,
                        margin:
                            const BubbleEdges.only(top: 16, left: 8, right: 16),
                        color: fromBot ? Colors.white : CustomColors.lightText,
                        alignment:
                            fromBot ? Alignment.topLeft : Alignment.topRight,
                        child: MarkdownBody(data: chatItem.content)),
                  );
                })),
        Align(
          alignment: Alignment.bottomLeft,
          child: Container(
              margin:
                  const EdgeInsets.only(top: 8, left: 8, right: 8, bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      child: CustomTextFormField(
                          onChanged: (value) => {},
                          controller: userMessageController,
                          minLines: 1,
                          maxLines: 4,
                          textInputType: TextInputType.multiline,
                          hintText: 'Ask anything to Pocket AI bot'),
                    ),
                  ),
                  Ink(
                    decoration: const ShapeDecoration(
                      color: CustomColors.secondary,
                      shape: CircleBorder(),
                    ),
                    width: 48,
                    height: 48,
                    child: apiCallInProgress
                        ? const CircularProgressIndicator(
                            color: CustomColors.primary,
                          )
                        : IconButton(
                            tooltip: 'Send',
                            onPressed: onSendPress,
                            color: CustomColors.primary,
                            icon: const Icon(Icons.send_rounded)),
                  )
                ],
              )),
        )
      ]),
    );
  }
}
