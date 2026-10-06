# Rhino reflects over its own classes when evaluating scripts.
-keep class org.mozilla.javascript.** { *; }
-dontwarn org.mozilla.javascript.**
-dontwarn javax.lang.model.**
-dontwarn java.beans.**
# kotlinx.serialization keeps generated serializers via @Serializable.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class **$$serializer { *; }
-keepclasseswithmembers class com.leeguoo.jrkan.** { kotlinx.serialization.KSerializer serializer(...); }
