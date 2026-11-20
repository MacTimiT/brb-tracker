# Commons Compress instantiates these classes reflectively when yt-dlp unpacks.
-keep,allowobfuscation class * implements org.apache.commons.compress.archivers.zip.ZipExtraField {
    public <init>();
}
