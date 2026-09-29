package dev.mulev.flureadium

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.util.AbsoluteUrl
import org.readium.r2.shared.util.toUri

internal class ReadiumReaderChannel(messenger: BinaryMessenger, name: String) :
    MethodChannel(messenger, name) {
    fun onPageChanged(locator: Locator?) =
        invokeMethod("onPageChanged", locator?.toJSON().toString())

    fun onExternalLinkActivated(url: AbsoluteUrl) =
        invokeMethod("onExternalLinkActivated", url.toString())

    fun onSelectionAction(action: String, locatorJson: String) =
        invokeMethod("onSelectionAction", mapOf("action" to action, "locator" to locatorJson))

    fun onDecorationTapped(id: String, locatorJson: String) =
        invokeMethod("onDecorationTapped", mapOf("id" to id, "locator" to locatorJson))

}
