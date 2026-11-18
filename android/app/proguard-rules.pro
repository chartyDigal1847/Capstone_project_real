# MediaPipe Graph initialization uses Flogger's stack-based caller lookup.
-keep class com.google.common.flogger.** { *; }

# MediaPipe's native PacketCreator looks up ProtoUtil.SerializedMessage fields
# by their original JNI names (for example, typeName).
-keep class com.google.mediapipe.framework.** { *; }

# These optional types are referenced by unused MediaPipe API methods but are
# not packaged in the Tasks Vision artifact.
-dontwarn com.google.auto.value.extension.memoized.Memoized
-dontwarn com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile
-dontwarn com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate

# Preserve protobuf-lite fields used by MediaPipe through reflection.
-keep class com.google.protobuf.** { *; }

# Retain useful stack trace metadata for native and Java exceptions.
-keepattributes SourceFile,LineNumberTable,EnclosingMethod,InnerClasses
