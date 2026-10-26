# MBox Android 混淆规则
# sing-box 内核库（gomobile bind 生成：Java 壳 + JNI native + go/Seq 运行时）
-keep class top.moneyfly.libbox.** { *; }   # sing-box AAR 的 Java 壳（gomobile 生成）
-keep class go.** { *; }
# gomobile 依赖 java.lang.reflect / JNI 注册，保留元数据
-keepattributes *Annotation*,InnerClasses,EnclosingMethod,Signature
-dontwarn go.**
