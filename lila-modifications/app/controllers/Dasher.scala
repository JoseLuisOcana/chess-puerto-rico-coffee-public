package controllers

import play.api.libs.json.*

import java.nio.file.Files

import lila.app.{ *, given }
import lila.i18n.{ LangList, LangPicker }
import lila.pref.ui.DasherJson

final class Dasher(env: Env) extends LilaController(env):

  private lazy val galleryJson = scalalib.data.SimpleMemo[Option[JsValue]](10.minutes.some): () =>
    val pathname = env.getFile.exec(s"public/lifat/background/gallery.json").toPath
    try Json.parse(Files.newInputStream(pathname)).some
    catch
      case e: Exception =>
        lila.log.system.warn(s"dasher error reading gallery json $pathname", e)
        none

  def get = Open:
    negotiateJson:
      ctx.me
        .so(env.streamer.api.isPotentialStreamer(_))
        .map: isStreamer =>
          val gallery = galleryJson.get()
          Ok:
            Json.obj(
              "lang" -> Json.obj(
                "current" -> ctx.lang.code,
                // Chess Puerto Rico Coffee (BUTTON 255, 2026-11-26): the site is ENGLISH ONLY - the menu offers only English
                "accepted" -> LangPicker.allFromRequestHeaders(ctx.req).map(_.code).filter(_.startsWith("en-")),
                "list" -> LangList.allChoices.filter(_._1.startsWith("en-"))
              ),
              "streamer" -> isStreamer
            ) ++ DasherJson(ctx.pref, gallery)
