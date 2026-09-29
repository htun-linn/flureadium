package dev.mulev.flureadium

import android.os.Parcel
import android.os.Parcelable
import org.readium.r2.navigator.Decoration

/** Style used to render the small note marker beside a noted passage. */
internal data class NoteMarkerDecorationStyle(val tint: Int) : Decoration.Style {
    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeInt(tint)
    }

    override fun describeContents(): Int = 0

    companion object CREATOR : Parcelable.Creator<NoteMarkerDecorationStyle> {
        override fun createFromParcel(source: Parcel): NoteMarkerDecorationStyle =
            NoteMarkerDecorationStyle(source.readInt())

        override fun newArray(size: Int): Array<NoteMarkerDecorationStyle?> =
            arrayOfNulls(size)
    }
}
