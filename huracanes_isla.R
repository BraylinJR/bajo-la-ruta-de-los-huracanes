# Bajo la ruta de los huracanes
# Tormentas y huracanes que han pasado cerca de La Española desde 1950,
# con datos de IBTrACS (NOAA).
#
# Además de estos paquetes, necesitas tener instalados
# rnaturalearthdata, gifski y av.

library(readr)
library(dplyr)
library(tidyr)
library(stringr)
library(lubridate)
library(ggplot2)
library(ggrepel)
library(sf)
library(rnaturalearth)
library(scales)
library(gganimate)

sf_use_s2(FALSE)


# Parámetros ----

desde       <- 1950
radio_km    <- 100
destacados  <- 6    # cuántos huracanes se muestran en color
zona        <- c(lat_min = 16.3, lat_max = 21.2, lon_min = -75.6, lon_max = -67.2)

fondo   <- "#0d1b2a"
colores <- c("Tormenta o depresión" = "#c9a227",
             "Huracán cat. 1-2"     = "#f4845f",
             "Huracán cat. 3-5"     = "#ff2e4c")

meses <- c("enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
           "agosto", "septiembre", "octubre", "noviembre", "diciembre")


# Datos ----

archivo <- "ibtracs.NA.list.v04r01.csv"

if (!file.exists(archivo)) {
  url <- paste0(
    "https://www.ncei.noaa.gov/data/international-best-track-archive-",
    "for-climate-stewardship-ibtracs/v04r01/access/csv/", archivo
  )
  download.file(url, archivo, mode = "wb")
}

# La segunda fila del archivo trae las unidades, así que se salta
columnas <- names(read_csv(archivo, n_max = 0, show_col_types = FALSE))

puntos <- read_csv(
  archivo,
  skip = 2,
  col_names = columnas,
  na = c("", " "),
  col_select = c(SID, SEASON, NAME, ISO_TIME, LAT, LON,
                 USA_WIND, USA_SSHS, TRACK_TYPE),
  show_col_types = FALSE
) |>
  filter(SEASON >= desde, TRACK_TYPE == "main") |>
  transmute(
    id        = SID,
    temporada = SEASON,
    nombre    = if_else(NAME == "NOT_NAMED", "Sin nombre", str_to_title(NAME)),
    fecha     = as_datetime(ISO_TIME),
    lat       = LAT,
    lon       = LON,
    viento_kt = coalesce(USA_WIND, 0),
    categoria = coalesce(USA_SSHS, -1),
    nivel     = cut(categoria, c(-Inf, 1, 3, Inf), labels = names(colores), right = FALSE)
  ) |>
  # Solo interesa la región alrededor de la isla
  filter(between(lat, 13, 25), between(lon, -80, -62))

# Distancia en km entre dos puntos (fórmula de haversine)
distancia_km <- function(lat1, lon1, lat2, lon2) {
  rad <- pi / 180
  a <- sin((lat2 - lat1) * rad / 2)^2 +
    cos(lat1 * rad) * cos(lat2 * rad) * sin((lon2 - lon1) * rad / 2)^2
  2 * 6371 * asin(sqrt(a))
}

isla <- ne_countries(
  scale = "medium",
  country = c("Dominican Republic", "Haiti"),
  returnclass = "sf"
)

# Distancias a la costa en una proyección en metros
isla_utm   <- st_transform(st_union(isla), 32619)
puntos_utm <- st_transform(st_as_sf(puntos, coords = c("lon", "lat"), crs = 4326), 32619)
radio      <- st_transform(st_buffer(isla_utm, radio_km * 1000), 4326)

puntos <- puntos |>
  mutate(
    km_isla = as.numeric(st_distance(puntos_utm, isla_utm)) / 1000,
    km_sd   = distancia_km(lat, lon, 18.4861, -69.9312)
  )

# Una fila por tormenta que pasó dentro del radio, con su fuerza al pasar
tormentas <- puntos |>
  filter(km_isla <= radio_km) |>
  summarise(
    temporada = first(temporada),
    nombre    = first(nombre),
    categoria = max(categoria),
    viento_kt = max(viento_kt),
    mes       = month(fecha[which.min(km_isla)]),
    .by = id
  ) |>
  left_join(summarise(puntos, km_sd = min(km_sd), .by = id), by = "id")


# Cifras clave ----

cat("\nTormentas a menos de ", radio_km, " km de la isla desde ", desde, ": ",
    nrow(tormentas), "\n", sep = "")
cat("Pasaron como huracán:", sum(tormentas$categoria >= 1), "\n")
cat("Pasaron como huracán mayor (cat. 3-5):", sum(tormentas$categoria >= 3), "\n")
cat("A menos de 100 km de Santo Domingo:", sum(tormentas$km_sd <= 100), "\n")

mes_top <- count(tormentas, mes, sort = TRUE) |> slice(1)
cat("Mes con más pasos: ", meses[mes_top$mes], " (",
    percent(mes_top$n / nrow(tormentas)), ")\n\n", sep = "")

tormentas |>
  slice_max(viento_kt, n = 10, with_ties = FALSE) |>
  select(temporada, nombre, categoria, viento_kt) |>
  print()

# Antes de los satélites muchas tormentas débiles no se registraban,
# así que el aumento por década no significa necesariamente más tormentas
tormentas |>
  count(decada = temporada %/% 10 * 10) |>
  print()


# Elementos del mapa ----

ciudades <- tibble(
  ciudad = c("Santo Domingo", "Santiago"),
  lat    = c(18.4861, 19.4517),
  lon    = c(-69.9312, -70.6970)
)

# Los más fuertes con nombre van en color; el resto queda de fondo
top <- tormentas |>
  filter(nombre != "Sin nombre") |>
  slice_max(viento_kt, n = destacados, with_ties = FALSE) |>
  mutate(etiqueta = paste0(nombre, " ", temporada, " · cat. ", categoria))

# Todas las rutas en una sola tabla. Las destacadas se ordenan al final
# para que queden dibujadas encima
rutas <- puntos |>
  semi_join(tormentas, by = "id") |>
  mutate(
    destacada = id %in% top$id,
    tramo     = if_else(destacada, as.character(nivel), "Otras tormentas"),
    tramo     = factor(tramo, levels = c("Otras tormentas", names(colores)))
  ) |>
  arrange(destacada, id, fecha) |>
  mutate(grupo = factor(id, levels = unique(id)))

# Cada etiqueta va sobre su ruta, en el punto más alejado de la isla
# que aún cae dentro del mapa, para no tapar la isla
anclas <- rutas |>
  filter(destacada) |>
  filter(
    between(lon, zona["lon_min"] + 0.4, zona["lon_max"] - 0.4),
    between(lat, zona["lat_min"] + 0.3, zona["lat_max"] - 0.3)
  ) |>
  slice_max(km_isla, n = 1, by = id, with_ties = FALSE) |>
  left_join(select(top, id, etiqueta), by = "id")

mapa_base <- list(
  geom_sf(data = radio, fill = NA, color = "#7f93a8", linetype = "dashed",
          linewidth = 0.4, inherit.aes = FALSE),
  geom_sf(data = isla, fill = "#24303f", color = "#4a5a6e",
          linewidth = 0.3, inherit.aes = FALSE),
  geom_path(aes(group = grupo, color = tramo, linewidth = destacada,
                alpha = destacada), lineend = "round"),
  geom_point(data = ciudades, shape = 21, fill = "white",
             color = fondo, size = 3, stroke = 1),
  geom_text(data = ciudades, aes(label = ciudad), color = "white",
            fontface = "bold", size = 4, nudge_y = -0.17),
  scale_color_manual(values = c("Otras tormentas" = "#6b7c90", colores),
                     drop = FALSE, name = NULL),
  scale_linewidth_manual(values = c(0.3, 1.2), guide = "none"),
  scale_alpha_manual(values = c(0.4, 1), guide = "none"),
  guides(color = guide_legend(override.aes = list(linewidth = c(0.8, 2, 2, 2)))),
  coord_sf(xlim = zona[c("lon_min", "lon_max")],
           ylim = zona[c("lat_min", "lat_max")], expand = FALSE),
  theme_void(base_size = 14),
  theme(
    plot.background = element_rect(fill = fondo, color = NA),
    plot.title      = element_text(color = "white", face = "bold", size = 26),
    plot.subtitle   = element_text(color = "#c9d6e3", size = 14,
                                   margin = margin(t = 4, b = 10)),
    plot.caption    = element_text(color = "#7f93a8", size = 9),
    legend.position = "bottom",
    legend.text     = element_text(color = "white"),
    legend.title    = element_text(color = "white"),
    plot.margin     = margin(20, 20, 15, 20)
  )
)

subtitulo <- paste0(
  nrow(tormentas), " tormentas pasaron a menos de ", radio_km,
  " km de la isla (línea punteada) desde ", desde,
  ".\nEn color, las ", destacados, " más fuertes según su fuerza en cada tramo."
)


# Mapa estático ----

mapa <- ggplot(rutas, aes(lon, lat)) +
  mapa_base +
  geom_label_repel(
    data = anclas, aes(label = etiqueta),
    size = 3.6, color = "white", fill = alpha(fondo, 0.9),
    label.size = 0, segment.color = "white", segment.size = 0.3,
    box.padding = 0.5, min.segment.length = 0, seed = 7
  ) +
  labs(
    title    = "Bajo la ruta de los huracanes",
    subtitle = subtitulo,
    caption  = "Fuente: IBTrACS, NOAA"
  )

ggsave("mapa_huracanes_isla.png", mapa, width = 12, height = 7.5, dpi = 300)


# Animación ----

acumulado <- tormentas |>
  count(temporada) |>
  complete(temporada = desde:max(temporada), fill = list(n = 0)) |>
  mutate(total = cumsum(n))

anim <- ggplot(rutas, aes(lon, lat)) +
  mapa_base +
  labs(
    title    = "Bajo la ruta de los huracanes",
    subtitle = subtitulo,
    caption  = "Fuente: IBTrACS, NOAA",
    tag      = "{current_frame}  ·  {acumulado$total[acumulado$temporada == as.numeric(current_frame)]} tormentas"
  ) +
  theme(
    plot.tag          = element_text(color = "white", face = "bold", size = 20, hjust = 0),
    plot.tag.position = c(0.05, 0.76)
  ) +
  transition_manual(temporada, cumulative = TRUE)

cuadros <- n_distinct(rutas$temporada) + 24  # años + pausa final

animate(anim, nframes = cuadros, fps = 8, end_pause = 24,
        width = 1080, height = 1080, res = 130, bg = fondo,
        renderer = gifski_renderer("huracanes_isla.gif"))

animate(anim, nframes = cuadros, fps = 8, end_pause = 24,
        width = 1080, height = 1080, res = 130, bg = fondo,
        renderer = av_renderer("huracanes_isla.mp4"))
