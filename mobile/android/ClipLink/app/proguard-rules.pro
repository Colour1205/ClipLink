# R8 rules for the release build, on top of the default optimize rules.
#
# Nothing of the app's own needs keeping: the only reflection is class
# literals for Intents and ComponentNames (which R8 follows), JSON is built
# and read by hand through org.json (a platform API, not shrunk), and
# Compose, CameraX, coroutines and lifecycle ship their own consumer rules.
# Anything that is persisted or sent on the wire is keyed by strings in the
# code, never by a class or field name, so renaming changes nothing there.

# The Activity log names an error by its class (see describeError): keep
# those names readable rather than a renamed "a.b".
-keepnames class * extends java.lang.Throwable

# Stack traces in logcat that mapping.txt can turn back into file and line.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
